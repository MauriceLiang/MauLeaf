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
        try check(manager.limit == 80 && manager.modeText.source == "限制充电未启用"
                  && manager.popoverLimitStatus.source == "未启用"
                  && manager.popoverFullChargeStatus.source == "未开启"
                  && manager.canToggleLimitFromCard && !manager.canToggleFullChargeFromCard
                  && manager.limitCardActionHint.source == "启用限制充电",
                  "initial card can enable limit but cannot start one-time full charge")
        manager.batteryStateText = "正在充电"
        try check(manager.popoverPowerStatus.source == "充电中"
                  && manager.popoverPowerStatus.localized(in: .english) == "Charging"
                  && manager.popoverPowerDetail.source == "已接电源，充电中",
                  "power row is compact while the full charging detail remains available")
        manager.batteryStateText = "已接电源，未充电"
        try check(manager.popoverPowerStatus.source == "已接电源"
                  && manager.popoverPowerStatus.localized(in: .english) == "Plugged in"
                  && manager.popoverPowerDetail.localized(in: .english) == "Connected to power, not charging",
                  "plugged-in status stays on one line without losing no-charge detail")
        manager.batteryStateText = "已接电源，已充满"
        try check(manager.popoverPowerStatus.localized(in: .english) == "Fully charged",
                  "fully charged state has a short distinct label")
        manager.batteryStateText = "电池供电"
        try check(manager.popoverPowerStatus.localized(in: .english) == "On battery",
                  "battery power stays a separate state")
        manager.batteryStateText = "正在充电"

        manager.requestLimit(85, immediate: true)
        try check(manager.limit == 85 && backend.applyCount == 0 && !manager.showNativeWriteConfirmation,
                  "changing the limit before activation only saves the local preference")

        manager.toggleLimitFromCard()
        try check(manager.showNativeWriteConfirmation && backend.applyCount == 0,
                  "first activation requires explicit hardware-write confirmation")
        manager.confirmNativeWrite()
        try await wait { backend.applyCount == 1 && !manager.isBusy }
        try check(backend.state.active && backend.state.upper == 85 && backend.state.lower == 83,
                  "confirmed activation writes the requested native upper and resume thresholds")
        try check(manager.hasOriginalStateSnapshot
                  && manager.popoverLimitStatus.source == "已启用 · 85%"
                  && manager.popoverLimitStatus.localized(in: .english) == "On · 85%"
                  && manager.canToggleLimitFromCard && manager.canToggleFullChargeFromCard
                  && manager.limitCardActionHint.source == "关闭限制充电",
                  "active card offers direct disable and one-time full actions")
        try check(!manager.isError
                  && manager.statusMessage.source == "充电上限已设为 85%，固件写入已验证。"
                  && manager.statusMessage.localized(in: .english) == "Charging limit set to 85%. Firmware write verified."
                  && !manager.statusMessage.source.contains("Fake native firmware"),
                  "limit success is concise and localized; raw helper audit text is never user-facing")

        manager.batteryPercent = 90
        try check(manager.fullChargeCardActionHint.localized(in: .english).contains("100%"),
                  "short Full charge title retains one-time behavior explanation on hover")
        manager.toggleFullChargeFromCard()
        try await wait { backend.beginCount == 1 && !manager.isBusy }
        try check(manager.fullOncePending && !backend.state.active && manager.hasOriginalStateSnapshot
                  && manager.popoverFullChargeStatus.source == "进行中"
                  && manager.popoverFullChargeStatus.localized(in: .english) == "Active"
                  && manager.popoverLimitStatus.source == "已暂停 · 85%"
                  && manager.popoverLimitStatus.localized(in: .english) == "Paused · 85%"
                  && manager.canToggleFullChargeFromCard
                  && manager.fullChargeCardActionHint.source == "取消本次充满",
                  "one-time card switches into actionable cancel state")
        try check(manager.statusMessage.source == "本次充满已开启，固件限充暂时关闭。"
                  && manager.statusMessage.localized(in: .english) == "One-time full charge started. Firmware charging limit temporarily disabled.",
                  "one-time full success uses localized compact feedback")
        manager.toggleFullChargeFromCard()
        try await wait { backend.cancelCount == 1 && !manager.isBusy }
        try check(!manager.fullOncePending && backend.state.active && backend.state.upper == 85
                  && manager.popoverFullChargeStatus.source == "未开启"
                  && manager.popoverLimitStatus.source == "已启用 · 85%",
                  "cancelled one-time full charge returns to normal charging-limit display")
        try check(manager.statusMessage.source == "已取消本次充满，原充电上限已恢复。"
                  && manager.statusMessage.localized(in: .english) == "One-time full charge canceled. Previous limit restored.",
                  "cancelling one-time full charge uses localized compact feedback")

        backend.failNextApply = true
        manager.requestLimit(90, immediate: true)
        try await wait { backend.applyCount == 2 && !manager.isBusy }
        try check(manager.isError, "failed native write is reported")
        manager.retryChargeRequest()
        try await wait { backend.applyCount == 3 && !manager.isBusy }
        try check(!manager.isError && backend.state.upper == 90 && manager.hasOriginalStateSnapshot,
                  "retry updates the active limit without overwriting the original snapshot")
        try check(manager.statusMessage.source == "充电上限已设为 90%，固件写入已验证。",
                  "automatic limit changes use the same localized confirmation")

        manager.isAdapterConnected = false
        try check(!manager.canToggleFullChargeFromCard && manager.canToggleLimitFromCard,
                  "loss of AC blocks one-time full but preserves safe restoration")
        manager.requestLimit(95, immediate: true)
        try check(backend.applyCount == 3 && manager.isError,
                  "native firmware writes are blocked without AC power")
        manager.isAdapterConnected = true

        manager.toggleLimitFromCard()
        try await wait { backend.restoreCount == 1 && !manager.isBusy }
        try check(!manager.hasOriginalStateSnapshot && !backend.state.active
                  && backend.state.upper == 80 && backend.state.lower == 78
                  && manager.popoverLimitStatus.source == "未启用"
                  && manager.canToggleLimitFromCard && !manager.canToggleFullChargeFromCard,
                  "card disable restores original firmware and disables one-time full pill")
        try check(manager.statusMessage.source == "已关闭限制充电，原始固件配置已恢复。"
                  && manager.statusMessage.localized(in: .english) == "Charging limit disabled. Original firmware configuration restored."
                  && manager.statusMessage.source.count < 30,
                  "turning off the limit shows a complete compact localized message")

        let allowed = await manager.prepareForTermination()
        try check(allowed, "app can quit after an already verified manual disable")
        try check(!backend.state.active && !backend.pending && backend.restoreCount == 1,
                  "quitting after manual disable leaves the original firmware state intact")

        try await testFirstLaunchDefersAuthorization()
        try await testMissingHelperQuitsWithoutAuthorization()
        try await testUnknownInstalledHelperDoesNotAssumeSafeState()
        try await testUpgradeRequiresExplicitEnable()
        try await testOutdatedActiveHelperCanBeRepairedWithoutFirmwareWrite()
        try await testInstallFailureDoesNotWriteFirmware()
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
        print("ChargeManagerTests: PASS (deferred first-use install, password-free Keep, safe read-only launch, recovery guards, existing restore and legacy coverage)")
    }

    @MainActor
    private static func testFirstLaunchDefersAuthorization() async throws {
        let backend = FixtureNativeFirmwareBackend()
        backend.helperAvailable = false
        var installs = 0
        let manager = ChargeManager(
            backend: backend,
            autoInstallNativeHelper: false,
            helperInstallerForTesting: {
                installs += 1
                backend.helperAvailable = true
            },
            helperArtifactsPresent: { false }
        )
        UserDefaults.standard.set(false, forKey: "nativeFirmwareWriteConfirmed")
        manager.start()
        try await wait { manager.helperNeedsInstallation }
        try check(installs == 0 && backend.applyCount == 0
                  && manager.currentState == nil && manager.popoverLimitStatus.source == "未启用",
                  "launch remains read-only and does not install a privileged helper")
        manager.isAdapterConnected = true
        manager.batteryPercent = 50
        manager.requestLimit(85, immediate: true)
        try check(installs == 0 && backend.applyCount == 0 && manager.limit == 85,
                  "setting charging limit before opting in only saves preference")
        manager.toggleLimitFromCard()
        try check(manager.showNativeWriteConfirmation && installs == 0,
                  "first card action requests in-app firmware consent before administrator privileges")
        manager.confirmNativeWrite()
        try await wait { installs == 1 && backend.applyCount == 1 && !manager.isBusy }
        try check(!manager.isError && backend.state.active && manager.hasOriginalStateSnapshot,
                  "a single authorized helper installation is followed by verified firmware activation")
        manager.disableLimit()
        try await wait { backend.restoreCount == 1 && !manager.isBusy }
        manager.enableLimit()
        try await wait { backend.applyCount == 2 && !manager.isBusy }
        try check(installs == 1, "later limit actions reuse the registered helper with no new password")
        let restored = await manager.prepareForTermination()
        let kept = await manager.finishQuitComponentCleanup(.keep)
        try check(restored && kept && installs == 1 && !backend.state.active,
                  "Keep exit performs exact restoration without re-installing or removing the helper")
        UserDefaults.standard.removeObject(forKey: "nativeFirmwareWriteConfirmed")
    }

    @MainActor
    private static func testMissingHelperQuitsWithoutAuthorization() async throws {
        let backend = FixtureNativeFirmwareBackend()
        backend.helperAvailable = false
        var installs = 0
        let manager = ChargeManager(
            backend: backend,
            autoInstallNativeHelper: false,
            helperInstallerForTesting: { installs += 1 },
            helperArtifactsPresent: { false }
        )
        manager.start()
        try await wait { manager.helperNeedsInstallation }
        let safe = await manager.prepareForTermination()
        let removed = await manager.finishQuitComponentCleanup(.remove)
        try check(safe,
                  "a fresh read-only installation can quit without root state to restore")
        try check(removed && installs == 0,
                  "removing a never-installed Helper does not require a password")
    }

    @MainActor
    private static func testUnknownInstalledHelperDoesNotAssumeSafeState() async throws {
        let backend = FixtureNativeFirmwareBackend()
        backend.helperAvailable = false
        var installs = 0
        let manager = ChargeManager(
            backend: backend,
            autoInstallNativeHelper: false,
            helperInstallerForTesting: { installs += 1 },
            helperArtifactsPresent: { true }
        )
        manager.start()
        try await wait { manager.helperStateUnknown }
        manager.isAdapterConnected = true
        try check(!manager.canEnableLimit && manager.popoverLimitStatus.source == "状态未知"
                  && installs == 0,
                  "unreachable installed helper or recovery artifacts never masquerade as an inactive limit")
        let allowed = await manager.prepareForTermination()
        try check(!allowed && installs == 0,
                  "unknown firmware state blocks safe quit rather than requesting surprise admin privileges")
    }

    @MainActor
    private static func testUpgradeRequiresExplicitEnable() async throws {
        let backend = FixtureNativeFirmwareBackend()
        backend.reportedHelperVersion = FirmwareLimitHelperProtocolVersion.current - 1
        var installs = 0
        let manager = ChargeManager(
            backend: backend,
            autoInstallNativeHelper: false,
            helperInstallerForTesting: {
                installs += 1
                backend.reportedHelperVersion = nil
            },
            helperArtifactsPresent: { true }
        )
        UserDefaults.standard.set(true, forKey: "nativeFirmwareWriteConfirmed")
        manager.start()
        try await wait { manager.helperNeedsUpgrade }
        try check(installs == 0 && backend.applyCount == 0
                  && manager.popoverLimitStatus.source == "未启用",
                  "startup detects stale helper without performing a privileged upgrade")
        manager.isAdapterConnected = true
        manager.enableLimit()
        try await wait { installs == 1 && backend.applyCount == 1 && !manager.isBusy }
        try check(!manager.isError && backend.state.active && manager.hasOriginalStateSnapshot,
                  "explicit enable upgrades once, checks new protocol and then writes safely")
    }

    @MainActor
    private static func testOutdatedActiveHelperCanBeRepairedWithoutFirmwareWrite() async throws {
        let backend = FixtureNativeFirmwareBackend()
        backend.state = FirmwareLimitHelperStateResponse(
            state: FirmwareLimitState(activationByte: 0x02, upper: 85, lower: 83)
        )
        backend.reportedHelperVersion = FirmwareLimitHelperProtocolVersion.current - 1
        var installs = 0
        let manager = ChargeManager(
            backend: backend,
            autoInstallNativeHelper: false,
            helperInstallerForTesting: {
                installs += 1
                backend.reportedHelperVersion = nil
            },
            helperArtifactsPresent: { true }
        )
        manager.start()
        try await wait { manager.helperNeedsUpgrade }
        try check(manager.canToggleLimitFromCard && !manager.canEnableLimit && installs == 0,
                  "stale active Helper never auto-upgrades, but offers explicit repair")
        try check(manager.limitCardActionHint.source == "修复控制服务",
                  "the card explicitly names the repair action rather than pretending the limit is inactive")
        manager.toggleLimitFromCard()
        try await wait { installs == 1 && !manager.isBusy && !manager.helperNeedsUpgrade }
        try check(backend.applyCount == 0 && backend.state.active
                  && manager.isLegacyActive && manager.canDisableLegacyLimit,
                  "manual Helper repair changes no SMC values and restores safe legacy-disable access")
    }

    @MainActor
    private static func testInstallFailureDoesNotWriteFirmware() async throws {
        let backend = FixtureNativeFirmwareBackend()
        backend.helperAvailable = false
        var installs = 0
        let manager = ChargeManager(
            backend: backend,
            autoInstallNativeHelper: false,
            helperInstallerForTesting: {
                installs += 1
                throw FixtureBackendError.injected
            },
            helperArtifactsPresent: { false }
        )
        UserDefaults.standard.set(true, forKey: "nativeFirmwareWriteConfirmed")
        manager.start()
        try await wait { manager.helperNeedsInstallation }
        manager.isAdapterConnected = true
        manager.enableLimit()
        try await wait { installs == 1 && manager.isError && !manager.isBusy }
        try check(backend.applyCount == 0 && manager.helperNeedsInstallation,
                  "cancelled or failed administrator authorization never writes firmware")
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
        try check(completed && actions.isEmpty && !backend.state.active
                  && backend.state.upper == 80 && backend.state.lower == 78,
                  "keep mode restores firmware without executing an admin script or unregistering launchd")
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
