import AppKit
import Foundation

@main
struct AppIconTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: appicontests <iconset directory or image>\n", stderr)
            exit(2)
        }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory) else {
            fatalError("Icon input is missing")
        }
        let expectedSizes = [
            "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
            "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
            "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
            "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
            "icon_512x512.png": 512, "icon_512x512@2x.png": 1024
        ]
        let files: [URL]
        if isDirectory.boolValue {
            files = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "png" }
            guard Set(files.map(\.lastPathComponent)) == Set(expectedSizes.keys) else { fatalError("Expected all ten macOS icon representations") }
        } else { files = [input] }
        for file in files {
            guard let image = NSImage(contentsOf: file) else { fatalError("Cannot decode icon: \(file.path)") }
            var proposed = NSRect(x: 0, y: 0, width: 1024, height: 1024)
            guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
                fatalError("Cannot read icon pixels")
            }
            let size = cg.width
            if isDirectory.boolValue, expectedSizes[file.lastPathComponent] != size {
                fatalError("Incorrect icon representation dimensions: \(file.lastPathComponent)")
            }
            guard size == cg.height else { fatalError("App icon must be square") }
            var pixels = [UInt8](repeating: 0, count: size * size * 4)
            pixels.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: size, height: size,
                    bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
            }
            let border = max(1, Int(Double(size) * 0.08))
            var minX = size, minY = size, maxX = -1, maxY = -1
            for y in 0..<size { for x in 0..<size {
                let alpha = pixels[(y * size + x) * 4 + 3]
                if (x < border || y < border || x >= size - border || y >= size - border), alpha != 0 {
                    fputs("FAIL: \(file.lastPathComponent) lacks a transparent outer margin at \(x),\(y)\n", stderr)
                    exit(1)
                }
                if alpha > 127 {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }}
            let width = Double(maxX - minX + 1) / Double(size)
            let height = Double(maxY - minY + 1) / Double(size)
            let range = size < 64 ? 0.72...0.88 : 0.77...0.84
            guard range.contains(width), range.contains(height),
                  abs(Double(minX + maxX + 1) / 2 - Double(size) / 2) <= 1,
                  abs(Double(minY + maxY + 1) / 2 - Double(size) / 2) <= 1 else {
                fputs("FAIL: \(file.lastPathComponent) artwork scale or centering: \(width), \(height)\n", stderr)
                exit(1)
            }
        }
        print("AppIconTests: PASS (\(files.count) representations; transparent margins, artwork scale and centering)")
    }
}
