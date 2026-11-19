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
        try check(allowed, "app can quit after an already verified manual disable")
        try check(!backend.state.active && !backend.pending && backend.restoreCount == 1,
                  "quitting after manual disable leaves the original firmware state intact")

        try await testAutomaticQuitRestore()
        try await testQuitDuringOneTimeFullCharge()
        try await testUnpluggedQuitIsDenied()
        try await testRestoreFailureBlocksQuit()
        try await testFalseRestoreAcknowledgmentBlocksQuit()
        try await testLegacyPreview4RestoresActivationOnQuit()
        try await testInactiveQuitNeedsNoFirmwareWrite()
        try await testUnknownFirmwareStateBlocksQuit()

        UserDefaults.standard.removeObject(forKey: "nativeFirmwareWriteConfirmed")
        print("ChargeManagerTests: PASS (opt-in activation, automatic quit restore, AC guard, failure retry, one-time full and legacy migration)")
    }

    @MainActor
    private static func activatedManager(
        backend: FixtureNativeFirmwareBackend
    ) async throws -> ChargeManager {
        UserDefaults.standard.set(true, forKey: "nativeFirmwareWriteConfirmed")
        let manager = ChargeManager(backend: backend, autoInstallNativeHelper: false)
        manager.start()
        try await wait { manager.currentState != nil && manager.backendReady }
        manager.isAdapterConnected = true
        manager.batteryPercent = 80
        manager.enableLimit()
        try await wait { backend.applyCount == 1 && !manager.isBusy }
        try check(backend.state.active && manager.hasOriginalStateSnapshot,
                  "test fixture enabled a limit while retaining the pre-MauLeaf snapshot")
        return manager
    }

    @MainActor
    private static func testAutomaticQuitRestore() async throws {
        let backend = FixtureNativeFirmwareBackend()
        let manager = try await activatedManager(backend: backend)
        manager.requestLimit(90, immediate: true)
        try await wait { backend.applyCount == 2 && !manager.isBusy }
        let allowed = await manager.prepareForTermination()
        try check(allowed && manager.isPreparingToQuit,
                  "normal quit succeeds after automatic firmware restoration")
        try check(backend.restoreCount == 1 && !backend.state.active
                  && backend.state.upper == 80 && backend.state.lower == 78
                  && !manager.hasOriginalStateSnapshot,
                  "normal quit restores the original activation and both thresholds without manual disable")
    }

    @MainActor
    private static func testQuitDuringOneTimeFullCharge() async throws {
        let backend = FixtureNativeFirmwareBackend()
        let manager = try await activatedManager(backend: backend)
        manager.beginOneTimeFullCharge()
        try await wait { backend.beginCount == 1 && !manager.isBusy }
        try check(backend.pending && !backend.state.active,
                  "a one-time full-charge task is active before quit")

        let allowed = await manager.prepareForTermination()
        try check(allowed && backend.restoreCount == 1
                  && !backend.pending && !backend.state.active
                  && !manager.hasOriginalStateSnapshot,
                  "quitting cancels one-time full charge and restores the original pre-activation firmware state")
        try check(backend.cancelCount == 0,
                  "quit never reactivates the current MauLeaf limit through cancelOneTimeCharge")
    }

    @MainActor
    private static func testUnpluggedQuitIsDenied() async throws {
        let backend = FixtureNativeFirmwareBackend()
        let manager = try await activatedManager(backend: backend)
        manager.isAdapterConnected = false
        let denied = await manager.prepareForTermination()
        try check(!denied && manager.isError && !manager.isPreparingToQuit,
                  "without AC power, quitting is denied rather than silently leaving the limit active")
        try check(backend.restoreCount == 0 && backend.state.active,
                  "an unplugged quit does not attempt an unsafe firmware write")
        manager.isAdapterConnected = true
        let retry = await manager.prepareForTermination()
        try check(retry && backend.restoreCount == 1 && !backend.state.active,
                  "reconnecting AC permits a safe automatic restore and quit")
    }

    @MainActor
    private static func testRestoreFailureBlocksQuit() async throws {
        let backend = FixtureNativeFirmwareBackend()
        let manager = try await activatedManager(backend: backend)
        backend.failNextRestore = true
        let denied = await manager.prepareForTermination()
        try check(!denied && manager.isError && !manager.isPreparingToQuit
                  && backend.state.active && manager.hasOriginalStateSnapshot,
                  "a helper restore error blocks normal termination and retains the snapshot")
        let retried = await manager.prepareForTermination()
        try check(retried && backend.restoreCount == 2 && !backend.state.active,
                  "the next normal quit retries original-state restore successfully")
    }

    @MainActor
    private static func testFalseRestoreAcknowledgmentBlocksQuit() async throws {
        let backend = FixtureNativeFirmwareBackend()
        let manager = try await activatedManager(backend: backend)
        backend.falselyReportRestoreSuccess = true
        let denied = await manager.prepareForTermination()
        try check(!denied && backend.state.active && manager.hasOriginalStateSnapshot,
                  "a successful helper acknowledgment cannot bypass independent firmware state read-back")
        let retried = await manager.prepareForTermination()
        try check(retried && !backend.state.active && backend.restoreCount == 2,
                  "quit succeeds once the real state is restored and verified")
    }

    @MainActor
    private static func testLegacyPreview4RestoresActivationOnQuit() async throws {
        let backend = FixtureNativeFirmwareBackend()
        backend.state = FirmwareLimitHelperStateResponse(
            state: FirmwareLimitState(activationByte: 0x02, upper: 85, lower: 83)
        )
        let manager = ChargeManager(backend: backend, autoInstallNativeHelper: false)
        manager.start()
        try await wait { manager.currentState != nil && manager.isLegacyActive }
        manager.isAdapterConnected = true
        let allowed = await manager.prepareForTermination()
        try check(allowed && backend.restoreCount == 1 && !backend.state.active,
                  "normal quit automatically deactivates a Preview 4 legacy limit")
        try check(backend.state.upper == 85 && backend.state.lower == 83,
                  "legacy quit does not invent or zero historical threshold values")
    }

    @MainActor
    private static func testInactiveQuitNeedsNoFirmwareWrite() async throws {
        let backend = FixtureNativeFirmwareBackend()
        let manager = ChargeManager(backend: backend, autoInstallNativeHelper: false)
        manager.start()
        try await wait { manager.currentState != nil && manager.backendReady }
        manager.isAdapterConnected = false
        let allowed = await manager.prepareForTermination()
        try check(allowed && backend.restoreCount == 0,
                  "an already-inactive clean installation can quit on battery without firmware writes")
    }

    @MainActor
    private static func testUnknownFirmwareStateBlocksQuit() async throws {
        let backend = FixtureNativeFirmwareBackend()
        let manager = try await activatedManager(backend: backend)
        backend.failNextRead = true
        let denied = await manager.prepareForTermination()
        try check(!denied && backend.state.active && !manager.isPreparingToQuit,
                  "unknown firmware state blocks quitting when restoration cannot be verified")
        let retried = await manager.prepareForTermination()
        try check(retried && !backend.state.active,
                  "reading the firmware and restoring it on retry permits quitting")
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
