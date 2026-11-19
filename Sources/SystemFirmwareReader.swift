import Foundation
import IOKit

/// Reads the firmware identifier from the IODeviceTree, including nested
/// nodes such as /chosen. The property is commonly exposed as CFData.
enum SystemFirmwareReader {
    private static let propertyName = "system-firmware-version"

    static func read() -> String? {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/")
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }

        // Keep support for firmware that places the property directly on the
        // IODeviceTree root.
        if let direct = IORegistryEntryCreateCFProperty(
            root, propertyName as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue(),
           let decoded = decode(direct) {
            return decoded
        }

        // Most Apple Silicon systems expose system-firmware-version on a
        // nested IODeviceTree entry. A root-only property lookup silently
        // returned an empty string and blocked an otherwise verified target.
        guard let nested = IORegistryEntrySearchCFProperty(
            root,
            kIODeviceTreePlane,
            propertyName as CFString,
            kCFAllocatorDefault,
            kIORegistryIterateRecursively
        )?.takeRetainedValue() else {
            return nil
        }
        return decode(nested)
    }

    static func decode(_ value: Any?) -> String? {
        let raw: String
        if let text = value as? String {
            raw = text
        } else if let data = value as? Data {
            let bytes = data.prefix { $0 != 0 }
            guard !bytes.isEmpty,
                  let text = String(data: Data(bytes), encoding: .utf8) else {
                return nil
            }
            raw = text
        } else {
            return nil
        }

        let normalized = raw.trimmingCharacters(
            in: .whitespacesAndNewlines.union(.controlCharacters)
        )
        return normalized.isEmpty ? nil : normalized
    }
}
