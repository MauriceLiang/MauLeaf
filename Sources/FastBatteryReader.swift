import Foundation
import IOKit

/// Fast, read-only battery telemetry for the UI.
/// The root Helper intentionally continues to use its existing ioreg reader
/// for firmware-write and restore permission checks.
enum MauLeafFastBatteryReader {
    static func read() -> MauLeafBatterySnapshot {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery")
        )
        guard service != IO_OBJECT_NULL else {
            return MauLeafBatteryStatusReader.read()
        }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service, &properties, kCFAllocatorDefault, 0
        ) == KERN_SUCCESS, let properties else {
            return MauLeafBatteryStatusReader.read()
        }

        let dictionary = properties.takeRetainedValue() as NSDictionary
        guard let battery = dictionary as? [String: Any] else {
            return MauLeafBatteryStatusReader.read()
        }
        return MauLeafBatteryStatusReader.parseProperties(battery)
    }
}
