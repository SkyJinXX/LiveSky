// Compares two images after converting both to 8-bit sRGB (embedded profiles are honoured, so a
// screenshot tagged with the display profile can be compared with an sRGB wallpaper PNG).
// usage: swift tools/compare-images.swift A.png B.png [--region x,y,w,h]
import CoreGraphics
import Foundation
import ImageIO

func load(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fputs("cannot read \(path)\n", stderr)
        exit(2)
    }
    return image
}

func pixels(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    buffer.withUnsafeMutableBytes { raw in
        let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return buffer
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    fputs("usage: compare-images A.png B.png [--region x,y,w,h]\n", stderr)
    exit(2)
}
let a = load(arguments[1]), b = load(arguments[2])
guard a.width == b.width, a.height == b.height else {
    print("size mismatch: \(a.width)x\(a.height) vs \(b.width)x\(b.height)")
    exit(1)
}
let width = a.width, height = a.height
var region = (x: 0, y: 0, w: width, h: height)
if let index = arguments.firstIndex(of: "--region"), index + 1 < arguments.count {
    let parts = arguments[index + 1].split(separator: ",").compactMap { Int($0) }
    if parts.count == 4 { region = (parts[0], parts[1], parts[2], parts[3]) }
}
let pa = pixels(a, width: width, height: height), pb = pixels(b, width: width, height: height)
var sums = [0, 0, 0], maximum = 0, histogram = [Int](repeating: 0, count: 256), count = 0
for y in region.y..<min(height, region.y + region.h) {
    for x in region.x..<min(width, region.x + region.w) {
        let offset = (y * width + x) * 4
        var worst = 0
        for channel in 0..<3 {
            let difference = abs(Int(pa[offset + channel]) - Int(pb[offset + channel]))
            sums[channel] += difference
            worst = max(worst, difference)
        }
        histogram[worst] += 1
        maximum = max(maximum, worst)
        count += 1
    }
}
func percentile(_ fraction: Double) -> Int {
    var cumulative = 0
    for (value, n) in histogram.enumerated() {
        cumulative += n
        if Double(cumulative) >= Double(count) * fraction { return value }
    }
    return 255
}
let means = sums.map { Double($0) / Double(count) }
print(String(format: "pixels %d  mean |diff| R %.3f G %.3f B %.3f (all %.3f)/255  p50 %d  p99 %d  max %d",
             count, means[0], means[1], means[2], means.reduce(0, +) / 3, percentile(0.5), percentile(0.99), maximum))
