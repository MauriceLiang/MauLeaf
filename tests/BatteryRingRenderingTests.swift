import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@MainActor
func verifyBatteryRingRendering(outputDirectory: URL) throws {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let leafURL = Bundle.main.url(forResource: "MenuBarLeafTemplate", withExtension: "png")!
    let leaf = NSBitmapImageRep(data: try Data(contentsOf: leafURL))!.cgImage!

    func alpha(_ image: CGImage) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        rgba.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
    }

    // Reference is the existing brand silhouette, centered at 28 pt in a 36 pt slot.
    let reference = CGContext(data: nil, width: 144, height: 144, bitsPerComponent: 8,
        bytesPerRow: 144 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    reference.clear(CGRect(x: 0, y: 0, width: 144, height: 144))
    reference.draw(leaf, in: CGRect(x: 16, y: 16, width: 112, height: 112))
    let expected = alpha(reference.makeImage()!)

    for (name, icon) in [("battery", BatteryRingIcon.battery), ("charging", .charging), ("adapter", .adapter)] {
        for scheme in [ColorScheme.dark, .light] {
            let content = BatteryStatusRing(percent: 93, tint: .yellow, icon: icon)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 4
            guard let image = renderer.cgImage, image.width == 272, image.height == 272,
                  let center = image.cropping(to: CGRect(x: 64, y: 64, width: 144, height: 144)) else {
                fatalError("Ring rendering failed or changed size")
            }
            let actual = alpha(center)
            let visible = actual.filter { $0 > 64 }.count
            guard visible > 500 else {
                fputs("FAIL: \(name) center is blank in \(scheme): \(visible) visible pixels\n", stderr)
                exit(1)
            }
            if icon == .battery {
                let intersection = zip(actual, expected).filter { $0 > 64 && $1 > 64 }.count
                let union = zip(actual, expected).filter { $0 > 64 || $1 > 64 }.count
                let overlap = Double(intersection) / Double(union)
                guard overlap > 0.90 else {
                    fputs("FAIL: rendered leaf differs from the brand silhouette/orientation: \(overlap)\n", stderr)
                    exit(1)
                }
            }
            let preview = ImageRenderer(content: content
                .padding(8)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.95)))
            preview.scale = 4
            let path = outputDirectory.appendingPathComponent("\(name)-\(scheme).png")
            let destination = CGImageDestinationCreateWithURL(path as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, preview.cgImage!, nil)
            guard CGImageDestinationFinalize(destination) else { fatalError("Could not save ring preview") }
        }
    }
    print("BatteryRingRenderingTests: PASS (all 3 icons visible in light/dark; leaf silhouette and orientation match)")
}
