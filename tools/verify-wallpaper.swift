// Checks what is actually on screen: captures each of the Dock's "Wallpaper-<space>" windows
// (one per Space and display) with screencapture, converts it from the embedded display profile
// to sRGB and compares it with the wallpaper PNG LiveSky last set.
// usage: verify-wallpaper [expected.png]   (default: the files in LiveSky's state.json)
import AppKit
import CoreGraphics
import Foundation
import ImageIO

func load(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func srgbPixels(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    buffer.withUnsafeMutableBytes { raw in
        let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return buffer
}

func compare(_ a: CGImage, _ b: CGImage) -> String {
    guard a.width == b.width, a.height == b.height else { return "size \(a.width)x\(a.height) vs \(b.width)x\(b.height)" }
    let pa = srgbPixels(a, width: a.width, height: a.height), pb = srgbPixels(b, width: b.width, height: b.height)
    var total = 0, maximum = 0, over2 = 0, count = 0
    var index = 0
    while index < pa.count {
        var worst = 0
        for channel in 0..<3 {
            let difference = abs(Int(pa[index + channel]) - Int(pb[index + channel]))
            total += difference
            worst = max(worst, difference)
        }
        if worst > 2 { over2 += 1 }
        maximum = max(maximum, worst)
        count += 1
        index += 4
    }
    return String(format: "mean |diff| %.3f/255, pixels off by >2: %.3f%%, max %d", Double(total) / Double(count * 3),
                  Double(over2) * 100 / Double(count), maximum)
}

// Which file should each display show?
var expected: [String: String] = [:]
if CommandLine.arguments.count > 1 {
    expected["*"] = CommandLine.arguments[1]
} else {
    let state = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LiveSky/state.json")
    if let data = try? Data(contentsOf: state),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let applied = json["applied"] as? [String: String] {
        expected = applied
    }
}
guard !expected.isEmpty else { print("nothing to compare"); exit(2) }

let screens = NSScreen.screens
var displays: [(name: String, uuid: String, frame: CGRect)] = []
for screen in screens {
    let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    let uuid = CGDisplayCreateUUIDFromDisplayID(number).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? ""
    // Window bounds use top-left global coordinates.
    let main = CGDisplayBounds(CGMainDisplayID())
    let frame = CGRect(x: screen.frame.minX, y: main.height - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
    displays.append((screen.localizedName, uuid, frame))
    print("display \(screen.localizedName) \(uuid) current URL: \(NSWorkspace.shared.desktopImageURL(for: screen)?.lastPathComponent ?? "-")")
}

let windows = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []).filter {
    ($0[kCGWindowOwnerName as String] as? String) == "Dock" && (($0[kCGWindowName as String] as? String) ?? "").hasPrefix("Wallpaper-")
}
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("livesky-verify-\(getpid())")
try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
var failures = 0
for window in windows {
    let number = window[kCGWindowNumber as String] as? Int ?? 0
    let name = window[kCGWindowName as String] as? String ?? ""
    let bounds = CGRect(dictionaryRepresentation: window[kCGWindowBounds as String] as! CFDictionary) ?? .zero
    let onscreen = (window[kCGWindowIsOnscreen as String] as? Bool) ?? false
    guard let display = displays.first(where: { $0.frame.intersects(bounds) }) else { continue }
    guard let file = expected[display.uuid] ?? expected["*"], let reference = load(file) else { continue }
    let capture = temporary.appendingPathComponent("\(number).png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-l", String(number), capture.path]
    try? process.run()
    process.waitUntilExit()
    guard let captured = load(capture.path) else { print("window \(number) \(name): capture failed"); failures += 1; continue }
    let result = compare(captured, reference)
    print("window \(number) \(name)\(onscreen ? " (current Space)" : "") on \(display.name): \(result)")
}
try? FileManager.default.removeItem(at: temporary)
