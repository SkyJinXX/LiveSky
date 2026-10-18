// Watches what the renderer does on screen while LiveSky updates: every state of its windows
// (alpha, level, on-screen) and any change of the frontmost app.
// usage: watch-focus <seconds>
import AppKit
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "15") ?? 15
let start = Date()
let end = start.addingTimeInterval(seconds)
func stamp() -> String { String(format: "%6.3f", Date().timeIntervalSince(start)) }
var lastFront = ""
var states = Set<String>()
var maxAlphaOnscreen = 0.0
var samples = 0
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    print(stamp(), "ACTIVATED", app?.bundleIdentifier ?? "?")
}
while Date() < end {
    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"
    if front != lastFront { print(stamp(), "frontmost:", front); lastFront = front }
    let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in windows where (window[kCGWindowOwnerName as String] as? String)?.contains("Renderer") == true {
        samples += 1
        let alpha = window[kCGWindowAlpha as String] as? Double ?? -1
        let onscreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false
        if onscreen { maxAlphaOnscreen = max(maxAlphaOnscreen, alpha) }
        let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let state = "window \(window[kCGWindowNumber as String]!) alpha \(alpha) layer \(window[kCGWindowLayer as String]!) onscreen \(onscreen) \(bounds["Width"] ?? 0)x\(bounds["Height"] ?? 0)"
        if !states.contains(state) { states.insert(state); print(stamp(), state) }
    }
}
print("renderer window samples: \(samples), highest alpha while on screen: \(maxAlphaOnscreen)")
