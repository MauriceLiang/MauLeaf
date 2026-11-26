import Foundation
import IOKit

enum MagSafeLEDObservationReader {
    static func read() -> MagSafeLEDObservation {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return unavailable }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties, let values = properties.takeRetainedValue() as NSDictionary as? [String: Any] else {
            return unavailable
        }
        let battery = MauLeafBatteryStatusReader.parseProperties(values)
        return MagSafeLEDObservation(
            externalConnected: battery.isACConnected,
            isCharging: (values["IsCharging"] as? NSNumber)?.boolValue,
            isFullyCharged: (values["FullyCharged"] as? NSNumber)?.boolValue,
            rawPercent: battery.precisePercent,
            magSafeConnected: battery.isACConnected == true && connectedMagSafe()
        )
    }

    private static var unavailable: MagSafeLEDObservation {
        MagSafeLEDObservation(externalConnected: nil, isCharging: nil,
                              isFullyCharged: nil, rawPercent: nil, magSafeConnected: false)
    }

    // Known AppleHPM/AppleTC port families. Require an explicit MagSafe 3
    // description and ConnectionActive, not the charger wattage or AC alone.
    // Unknown or inconsistent registry data fail closed.
    private static func connectedMagSafe() -> Bool {
        var found: [Bool] = []
        for className in ["AppleHPMInterfaceType11", "AppleTCControllerType11"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while true {
                let port = IOIteratorNext(iterator)
                if port == 0 { break }
                defer { IOObjectRelease(port) }
                var raw: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(port, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let raw, let properties = raw.takeRetainedValue() as NSDictionary as? [String: Any] else { continue }
                let names = [properties["Description"], properties["PortDescription"], properties["PortTypeDescription"]]
                    .compactMap { $0 as? String }
                guard names.contains(where: { $0 == "MagSafe 3" || $0.hasPrefix("Port-MagSafe 3") }) else { continue }
                guard let active = properties["ConnectionActive"] as? NSNumber else { return false }
                found.append(active.boolValue)
            }
        }
        return !found.isEmpty && found.allSatisfy { $0 }
    }
}
