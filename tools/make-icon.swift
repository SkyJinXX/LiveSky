// Draws the LiveSky app icon (a dusk sky with a setting sun) and writes Resources/AppIcon.icns.
// The icon is original artwork; it is not taken from WeatherUI.
// usage: swift tools/make-icon.swift   (run from the repository root)
import AppKit
import CoreGraphics

let master = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon() -> CGImage {
    let context = CGContext(data: nil, width: master, height: master, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: 824 pt artwork centred on a 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.35))
    context.addPath(shape)
    context.setFillColor(color(0x0B1E44))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let sky = CGGradient(colorsSpace: space, colors: [color(0x081634), color(0x1C3F7A), color(0x4F78B4), color(0xD99A7A), color(0xF4C27F)] as CFArray,
                         locations: [0, 0.38, 0.66, 0.88, 1])!
    context.drawLinearGradient(sky, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Stars fading out towards the horizon.
    let stars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (230, 820, 7, 0.95), (330, 760, 4, 0.7), (450, 860, 5, 0.85), (600, 800, 3.5, 0.6), (700, 870, 6, 0.9),
        (790, 760, 4, 0.65), (180, 690, 3.5, 0.5), (520, 700, 3, 0.45), (860, 650, 3, 0.4), (380, 640, 2.5, 0.35),
    ]
    for (x, y, radius, alpha) in stars {
        context.setFillColor(color(0xFFFFFF, alpha))
        context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }

    // Glow and sun low over the horizon.
    let sunCentre = CGPoint(x: 600, y: 250)
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFE3A3, 0.95), color(0xFFB36B, 0.45), color(0xFF9A5A, 0)] as CFArray,
                          locations: [0, 0.35, 1])!
    context.drawRadialGradient(glow, startCenter: sunCentre, startRadius: 0, endCenter: sunCentre, endRadius: 360, options: [])
    let disc = CGGradient(colorsSpace: space, colors: [color(0xFFFDF2), color(0xFFE9B0)] as CFArray, locations: [0, 1])!
    context.saveGState()
    context.addEllipse(in: CGRect(x: sunCentre.x - 92, y: sunCentre.y - 92, width: 184, height: 184))
    context.clip()
    context.drawRadialGradient(disc, startCenter: sunCentre, startRadius: 0, endCenter: sunCentre, endRadius: 92, options: [])
    context.restoreGState()

    // Soft haze along the bottom edge.
    let haze = CGGradient(colorsSpace: space, colors: [color(0xFFD7A0, 0.55), color(0xFFD7A0, 0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(haze, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 300), options: [])

    // Subtle inner highlight on the top edge.
    context.addPath(shape)
    context.setStrokeColor(color(0xFFFFFF, 0.12))
    context.setLineWidth(4)
    context.strokePath()
    context.restoreGState()
    return context.makeImage()!
}

func write(_ image: CGImage, size: Int, to url: URL) {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
}

let icon = drawIcon()
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    write(icon, size: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    write(icon, size: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
write(icon, size: 1024, to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
