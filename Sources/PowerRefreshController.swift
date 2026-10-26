import AppKit
import IOKit
import IOKit.ps

enum NativeBatteryPower {
    static func read() -> BatteryPowerSample? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let values = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        return BatteryPowerSample(properties: values)
    }

    static func sourceType() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return nil }
        return type as String
    }
}

@MainActor
final class PowerRefreshController {
    private let read: @Sendable () -> BatteryPowerSample?
    private let onUpdate: (BatteryPowerSample?) -> Void
    private let onSystemChange: () -> Void
    private var timer: Timer?
    private var sampleTask: Task<Void, Never>?
    private var sampleGeneration = 0
    private var immediatePending = false
    private var visible = false
    private var sleeping = false
    private var lastSample: BatteryPowerSample?
    private var powerSource: CFRunLoopSource?
    private var lastSourceType: String?
    private var workspaceObservers: [NSObjectProtocol] = []
    private let workspaceNotifications = NSWorkspace.shared.notificationCenter
    private(set) var refreshInterval: TimeInterval?
    var isSampling: Bool { sampleTask != nil }

    init(read: @escaping @Sendable () -> BatteryPowerSample? = { NativeBatteryPower.read() },
         onUpdate: @escaping (BatteryPowerSample?) -> Void,
         onSystemChange: @escaping () -> Void) {
        self.read = read
        self.onUpdate = onUpdate
        self.onSystemChange = onSystemChange
    }

    deinit {
        timer?.invalidate()
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        for observer in workspaceObservers { workspaceNotifications.removeObserver(observer) }
    }

    func startObservingSystemEvents() {
        guard workspaceObservers.isEmpty else { return }
        lastSourceType = NativeBatteryPower.sourceType()
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let controller = Unmanaged<PowerRefreshController>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak controller] in controller?.powerSourceDidChange() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        workspaceObservers.append(workspaceNotifications.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.suspend() } })
        workspaceObservers.append(workspaceNotifications.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.resume() } })
    }

    func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        sampleGeneration += 1
        if value { updateTimer(); refreshNow() }
        else { stopTimer(); immediatePending = false }
    }

    func suspend() {
        sleeping = true
        sampleGeneration += 1
        immediatePending = false
        stopTimer()
    }

    func resume() {
        sleeping = false
        updateTimer()
        onSystemChange()
        refreshNow()
    }

    func refreshNow() {
        guard visible, !sleeping else { return }
        if sampleTask != nil { immediatePending = true; return }
        sampleIfNeeded()
    }

    private func powerSourceDidChange() {
        let type = NativeBatteryPower.sourceType()
        // IOPS also reports percentage/time changes. Only a source transition
        // warrants an immediate control refresh, avoiding notification storms.
        guard type != lastSourceType else { return }
        lastSourceType = type
        onSystemChange()
        refreshNow()
    }

    func sampleIfNeeded() {
        guard visible, !sleeping, sampleTask == nil else { return }
        let generation = sampleGeneration
        let read = read
        sampleTask = Task { [weak self] in
            let sample = await Task.detached(priority: .utility, operation: read).value
            guard let self else { return }
            self.sampleTask = nil
            if self.visible, !self.sleeping, generation == self.sampleGeneration {
                self.lastSample = sample
                self.onUpdate(sample)
                self.updateTimer()
            }
            if self.immediatePending {
                self.immediatePending = false
                self.refreshNow()
            }
        }
    }

    private func updateTimer() {
        guard visible, !sleeping else { stopTimer(); return }
        let interval = lastSample?.refreshInterval ?? 5
        guard refreshInterval != interval else { return }
        stopTimer()
        refreshInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleIfNeeded() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        refreshInterval = nil
    }
}
