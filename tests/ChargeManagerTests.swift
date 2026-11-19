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
        try await testUnpluggedManualDisableRestoresImmediately()
        try await testUnpluggedQuitRestoresImmediately()
        try await testQuitKeepsComponentsAfterRestore()
        try await testQuitRemovesComponentsAfterRestore()
        try await testComponentCleanupFailureBlocksNormalQuit()
        try await testUnpluggedLowBatteryQuitBlocked()
        try await testUnpluggedLegacyQuitRequiresExplicitOverride()
        try await testUnpluggedOneTimeQuitRestoresImmediately()
        try await testRestoreFailureBlocksQuit()
        try await testFalseRestoreAcknowledgmentBlocksQuit()
        try await testLegacyPreview4RestoresActivationOnQuit()
        try await testInactiveQuitNeedsNoFirmwareWrite()
        try await testUnknownFirmwareStateBlocksQuit()

        UserDefaults.standard.removeObject(forKey: "nativeFirmwareWriteConfirmed")
        print("ChargeManagerTests: PASS (AC/battery quit restore, keep/remove native lifecycle, cleanup-failure protection, manual disable, one-time full and legacy migration)")
    }

    @MainActor
    private static func activatedManager(
        backend: FixtureNativeFirmwareBackend,
        exitLifecycle: ((QuitComponentPolicy) async throws -> Void)? = nil
    ) async throws -> ChargeManager {
        UserDefaults.standard.set(true, forKey: "nativeFirmwareWriteConfirmed")
        let manager = ChargeManager(
            backend: backend,
            autoInstallNativeHelper: false,
            exitLifecycleForTesting: exitLifecycle
        )
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
    private static func testUnpluggedManualDisableRestoresImmediately() async throws {
        let backend = FixtureNativeFirmwareBackend()
        let manager = try await activatedManager(backend: backend)
        backend.acConnected = false
        manager.isAdapterConnected = false
        try check(manager.canDisableLimit,
                  "Disable remains available on battery")
        manager.disableLimit()
        try await wait { backend.restoreCount == 1 && !manager.isBusy }
        try check(!manager.restorePending && !manager.isError
                  && !backend.state.active && !manager.hasOriginalStateSnapshot
                  && backend.state.upper == 80 && backend.state.lower == 78,
                  "manual disable on validated battery power restores all three original keys immediately")
    }

    @MainActor
    private static func testUnpluggedQuitRestoresImmediately() async throws {
        let backend = FixtureNativeFirmwareBackend()
        let manager = try await activatedManager(backend: backend)
        manager.requestLimit(90, immediate: true)
        try await wait { backend.applyCount == 2 && !manager.isBusy }
        backend.acConnected = false
        manager.isAdapterConnected = false
        let allowed = await manager.prepareForTermination()
        try check(allowed && manager.isPreparingToQuit && !manager.isError,
                  "normal quit on battery is allowed after verified restoration")
        try check(backend.restoreCount == 1 && !backend.state.active
                  && backend.state.upper == 80 && backend.state.lower == 78
                  && !manager.hasOriginalStateSnapshot && !backend.pending
                  && !manager.restorePending,
                  "battery-only normal quit restores exact original three keys and clears durable snapshot")
    }

    @MainActor
    private static func testQuitKeepsComponentsAfterRestore() async throws {
        let backend = FixtureNativeFirmwareBackend()
        var actions: [QuitComponentPolicy] = []
        let manager = try await activatedManager(backend: backend) { policy in
            actions.append(policy)
        }
        backend.acConnected = false
        manager.isAdapterConnected = false
        let restored = await manager.prepareForTermination()
        try check(restored && manager.didVerifyFirmwareOnQuit && actions.isEmpty,
                  "no helper stop or removal occurs before firmware restoration")
        let completed = await manager.finishQuitComponentCleanup(.keep)
        try check(completed && actions == [.keep] && !backend.state.active
                  && backend.state.upper == 80 && backend.state.lower == 78,
                  "keep mode starts only after full unplugged restore and retains files")
    }

    @MainActor
    private static func testQuitRemovesComponentsAfterRestore() async throws {
        let backend = FixtureNativeFirmwareBackend()
        var actions: [QuitComponentPolicy] = []
        let manager = try await activatedManager(backend: backend) { policy in
            actions.append(policy)
        }
        let restored = await manager.prepareForTermination()
        try check(restored && actions.isEmpty && manager.didVerifyFirmwareOnQuit,
                  "AC restore must complete before removal action")
        let completed = await manager.finishQuitComponentCleanup(.remove)
        try check(completed && actions == [.remove]
                  && !manager.hasOriginalStateSnapshot && !backend.state.active,
                  "remove mode executes only after exact original restore and verification")
    }

    @MainActor
    private static func testComponentCleanupFailureBlocksNormalQuit() async throws {
        let backend = FixtureNativeFirmwareBackend()
        let manager = try await activatedManager(backend: backend) { _ in
            throw FixtureBackendError.injected
        }
        let restored = await manager.prepareForTermination()
        try check(restored,
                  "fixture firmware restore succeeds before cleanup failure")
        let completed = await manager.finishQuitComponentCleanup(.remove)
        try check(!completed && !manager.isPreparingToQuit
                  && manager.didVerifyFirmwareOnQuit && manager.isError
                  && !backend.state.active,
                  "failed system cleanup blocks normal quit without pretending firmware restore failed")

        let secondBackend = FixtureNativeFirmwareBackend()
        var actionCount = 0
        let noCleanup = try await activatedManager(backend: secondBackend) { _ in
            actionCount += 1
        }
        secondBackend.failNextRestore = true
        let denied = await noCleanup.prepareForTermination()
        let cleanupAllowed = await noCleanup.finishQuitComponentCleanup(.remove)
        try check(!denied && actionCount == 0 && !cleanupAllowed,
                  "failed firmware restore must never trigger a delete-components action")
    }

    @MainActor
    private static func testUnpluggedLowBatteryQuitBlocked() async throws {
        let backend = FixtureNativeFirmwareBackend()
        let manager = try await activatedManager(backend: backend)
        backend.acConnected = false
        backend.offlineRestoreAllowed = false
        manager.isAdapterConnected = false
        let denied = await manager.prepareForTermination()
        try check(!denied && !manager.isPreparingToQuit && manager.isError,
                  "low battery or unverified power source cannot silently pass normal quit")
        try check(backend.restoreCount == 1 && backend.state.active
                  && manager.hasOriginalStateSnapshot && manager.restorePending,
                  "failed offline restore preserves helper snapshot and durable recovery request")
        backend.acConnected = true
        manager.isAdapterConnected = true
        let retried = await manager.prepareForTermination()
        try check(retried && !backend.state.active && !manager.restorePending
                  && !manager.hasOriginalStateSnapshot,
                  "after AC reconnection user can retry and safely quit")
    }

    @MainActor
    private static func testUnpluggedLegacyQuitRequiresExplicitOverride() async throws {
        let backend = FixtureNativeFirmwareBackend()
        backend.state = FirmwareLimitHelperStateResponse(
            state: FirmwareLimitState(activationByte: 0x02, upper: 85, lower: 83)
        )
        let manager = ChargeManager(backend: backend, autoInstallNativeHelper: false)
        manager.start()
        try await wait { manager.isLegacyActive }
        backend.acConnected = false
        manager.isAdapterConnected = false
        let denied = await manager.prepareForTermination()
        try check(!denied && backend.pendingLegacyRestore && manager.restorePending,
                  "without original snapshot unplugged legacy quit must warn rather than silently claim restoration")
        backend.acConnected = true
        let retried = await manager.prepareForTermination()
        try check(retried && !backend.state.active && backend.state.upper == 85
                  && backend.state.lower == 83,
                  "legacy AC restoration deactivates bfF0 while preserving unknown historical thresholds")
    }

    @MainActor
    private static func testUnpluggedOneTimeQuitRestoresImmediately() async throws {
        let backend = FixtureNativeFirmwareBackend()
        let manager = try await activatedManager(backend: backend)
        manager.beginOneTimeFullCharge()
        try await wait { backend.beginCount == 1 && backend.pending && !manager.isBusy }
        backend.acConnected = false
        manager.isAdapterConnected = false
        let allowed = await manager.prepareForTermination()
        try check(allowed && !backend.pending && !backend.state.restorePending,
                  "unplugged normal quit stops one-time charge and finishes immediate restoration")
        try check(!backend.state.active && backend.state.upper == 80
                  && backend.state.lower == 78 && !manager.hasOriginalStateSnapshot,
                  "one-time charge quit restores the original values, not the temporary limited state")
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
