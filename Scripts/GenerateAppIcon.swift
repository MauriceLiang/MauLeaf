import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// ICNS consumes the full canvas, so its artwork needs transparent margins.
// Local comparison icons occupy about 80% of their canvas. Keep the original
// artwork intact and center it within 824 of 1024 pixels at every resolution.
guard CommandLine.arguments.count == 3 else {
    fputs("Usage: GenerateAppIcon.swift <1024px source PNG> <output.iconset>\n", stderr)
    exit(2)
}
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == 1024, image.height == 1024 else {
    fputs("App icon source must be a readable 1024×1024 image.\n", stderr)
    exit(1)
}
let representations = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]
do {
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
    for (size, filename) in representations {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let side = CGFloat(size)
        let artwork = side * 824 / 1024
        let inset = (side - artwork) / 2
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: inset, y: inset, width: artwork, height: artwork))
        guard let rendered = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                outputURL.appendingPathComponent(filename) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
} catch {
    fputs("App icon generation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
