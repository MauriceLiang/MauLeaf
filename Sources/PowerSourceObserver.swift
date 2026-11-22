import Foundation
import CoreFoundation
import IOKit.ps

/// Low-overhead system notification for AC connect/disconnect and battery
/// state changes. No polling thread, XPC request, firmware write or new daemon.
@MainActor
final class MauLeafPowerSourceObserver {
    private let onChange: @MainActor () -> Void
    private var runLoopSource: CFRunLoopSource?
    private var started = false

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    @discardableResult
    func start() -> Bool {
        guard !started else { return true }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let observer = Unmanaged<MauLeafPowerSourceObserver>
                .fromOpaque(context).takeUnretainedValue()
            // The IOKit callback may execute outside the Swift main actor.
            Task { @MainActor in observer.deliverIfActive() }
        }, context)?.takeRetainedValue() else {
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes)
        runLoopSource = source
        started = true
        return true
    }

    private func deliverIfActive() {
        guard started else { return }
        onChange()
    }

    func stop() {
        guard started else { return }
        started = false
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes)
            runLoopSource = nil
        }
    }
}
