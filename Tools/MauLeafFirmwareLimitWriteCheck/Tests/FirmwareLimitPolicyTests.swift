import Foundation
import Darwin

@main
private enum FirmwareLimitPolicyTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
        print("PASS: \(message)")
    }

    static func main() {
        expect(
            FirmwareLimitPolicy.encodeLittleEndian(80) == [0x50, 0x00, 0x00, 0x00],
            "80 percent encodes as little-endian ui32"
        )
        expect(
            FirmwareLimitPolicy.decodeLittleEndian([0x4E, 0x00, 0x00, 0x00]) == 78,
            "78 percent decodes from little-endian ui32"
        )
        expect(
            FirmwareLimitPolicy.decodeLittleEndian([0x4E, 0x00, 0x00]) == nil,
            "short ui32 payload is rejected"
        )
        expect(
            FirmwareLimitPolicy.isValidPair(upper: 80, lower: 78),
            "80/78 is a valid upper/lower pair"
        )
        expect(
            !FirmwareLimitPolicy.isValidPair(upper: 80, lower: 80),
            "lower threshold must be below upper limit"
        )
        expect(
            !FirmwareLimitPolicy.isValidPair(upper: 101, lower: 98),
            "values above 100 percent are rejected"
        )
        expect(
            FirmwareLimitPolicy.hasExpectedShape(key: "bfF0", size: 1, type: "ui8"),
            "bfF0 requires one-byte ui8 metadata"
        )
        expect(
            FirmwareLimitPolicy.hasExpectedShape(key: "bfD0", size: 4, type: "ui32"),
            "bfD0 requires four-byte ui32 metadata"
        )
        expect(
            !FirmwareLimitPolicy.hasExpectedShape(key: "CH0I", size: 1, type: "ui8"),
            "adapter-input keys are not accepted as charge-limit keys"
        )
        print("All firmware-limit policy tests passed.")
    }
}
