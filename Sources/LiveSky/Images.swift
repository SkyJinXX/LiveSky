import CoreGraphics
import Foundation
import ImageIO

struct ImageCheckFailure: Error {
    var check: String
    var detail: String
}

enum ImageTools {
    /// The verified WeatherUI composition size (points, rendered at 1x).
    static let sourceWidth = 1826
    static let sourceHeight = 1344
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Reads the renderer's PNG and rejects anything that is not a real sky: wrong size,
    /// transparent, or a single flat colour.
    static func loadValidatedSource(_ url: URL) -> Result<CGImage, ImageCheckFailure> {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return .failure(ImageCheckFailure(check: "PNG UNREADABLE", detail: url.lastPathComponent))
        }
        guard image.width == sourceWidth, image.height == sourceHeight else {
            return .failure(ImageCheckFailure(check: "PNG SIZE",
                                              detail: "expected \(sourceWidth) × \(sourceHeight), found \(image.width) × \(image.height)"))
        }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: sRGB,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return .failure(ImageCheckFailure(check: "PNG UNREADABLE", detail: "could not decode pixels")) }

        var transparent = 0
        var histogram = [Int](repeating: 0, count: 256)
        pixels.withUnsafeBufferPointer { buffer in
            var index = 0
            while index < buffer.count {
                if buffer[index + 3] < 250 { transparent += 1 }
                let luma = (Int(buffer[index]) * 54 + Int(buffer[index + 1]) * 183 + Int(buffer[index + 2]) * 19) >> 8
                histogram[luma] += 1
                index += 4
            }
        }
        let total = width * height
        let transparentShare = Double(transparent) / Double(total)
        if transparentShare > 0.005 {
            return .failure(ImageCheckFailure(check: "PNG TRANSPARENT",
                                              detail: String(format: "%.1f%% of pixels are transparent", transparentShare * 100)))
        }
        let low = percentile(histogram, total: total, 0.01), high = percentile(histogram, total: total, 0.99)
        if high - low < 3 {
            return .failure(ImageCheckFailure(check: "PNG FLAT", detail: "single flat colour (luminance \(low)–\(high))"))
        }
        return .success(image)
    }

    private static func percentile(_ histogram: [Int], total: Int, _ fraction: Double) -> Int {
        let target = Int(Double(total) * fraction)
        var cumulative = 0
        for (value, count) in histogram.enumerated() {
            cumulative += count
            if cumulative > target { return value }
        }
        return 255
    }

    /// Scales the render to the display's pixel width and crops the bottom, keeping WeatherUI's
    /// composition (sun, moon, light effects) intact. A display taller than the render is
    /// filled by height and cropped evenly at the sides instead.
    static func compose(_ source: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        let sourceWidth = Double(source.width), sourceHeight = Double(source.height)
        let widthScale = Double(width) / sourceWidth, heightScale = Double(height) / sourceHeight
        let rect: CGRect
        if widthScale >= heightScale {
            let drawnHeight = sourceHeight * widthScale
            // Core Graphics has its origin at the bottom left: align the tops, crop the bottom.
            rect = CGRect(x: 0, y: Double(height) - drawnHeight, width: Double(width), height: drawnHeight)
        } else {
            let drawnWidth = sourceWidth * heightScale
            rect = CGRect(x: (Double(width) - drawnWidth) / 2, y: 0, width: drawnWidth, height: Double(height))
        }
        context.draw(source, in: rect)
        return context.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, "public.png" as CFString, 1, nil) else {
            throw LiveSkyError.wallpaper("could not create \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporary)
            throw LiveSkyError.wallpaper("could not write \(url.lastPathComponent)")
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw LiveSkyError.wallpaper("could not move \(url.lastPathComponent) into place")
        }
    }
}
