import Foundation

enum FirmwareLimitPolicy {
    static let requiredKeyShapes: [String: (size: Int, type: String)] = [
        "bfF0": (1, "ui8"),
        "bfD0": (4, "ui32"),
        "bfE0": (4, "ui32")
    ]

    static func encodeLittleEndian(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ]
    }

    static func decodeLittleEndian(_ bytes: [UInt8]) -> UInt32? {
        guard bytes.count >= 4 else { return nil }
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }

    static func isValidPair(upper: Int, lower: Int) -> Bool {
        (5...100).contains(upper)
            && (5...100).contains(lower)
            && lower < upper
    }

    static func hasExpectedShape(key: String, size: Int, type: String) -> Bool {
        guard let expected = requiredKeyShapes[key] else { return false }
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines)
        if size == 0 {
            return normalizedType.isEmpty || normalizedType == expected.type
        }
        return expected.size == size && expected.type == normalizedType
    }
}
