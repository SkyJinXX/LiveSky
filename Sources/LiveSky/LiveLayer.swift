import AppKit
import IOKit.ps

/// What the live sky draws: the inputs of the wallpaper render underneath it.
struct LiveScene: Equatable {
    var weather: WeatherSnapshot
    var date: Date
}

extension LiveCap {
    var title: String { self == .still ? L("live.cap.still") : L("live.cap.fps", rawValue) }
    /// What the renderer is told; 0 leaves WeatherUI's own rate alone, which never exceeds 60.
    var rendererFPS: Int { self == .fps60 ? 0 : rawValue }
}

/// The live sky: WeatherUI's animation in `LiveSkyRenderer --live`, one process per display, in a
/// click-through window behind the desktop icons. The wallpaper underneath shows the same scene,
/// so stopping or pausing the live sky never changes what the desktop shows, only whether it moves.
///
/// It runs while it is switched on, the ceiling for the current power source isn't "still" and the
/// controller allows it (set up, not paused, compatible, displays awake). A renderer pauses while
/// its desktop is mostly covered, the screen is locked or the screen saver runs; everything stops
/// while the Mac is hot. After three failures in a row it waits for the next scene.
@MainActor
final class LiveLayer {
    enum Power: String { case adapter, battery, lowPower }

    /// A renderer pauses below this share of its desktop showing and resumes at the second.
    static let pauseBelow = 0.15
    static let resumeAt = 0.25

    /// Called when something the menu shows changes.
    var onChange: (() -> Void)?

    private(set) var settings = Settings()
    private(set) var scene: LiveScene?
    private(set) var power = Power.adapter
    private(set) var failure: String?
    private(set) var gaveUp = false
    private var displays: [Display] = []
    private var allowed = false
    private var renderers: [String: LiveRenderer] = [:]
    /// A display's previous renderer, kept on screen until its successor has faded in.
    private var outgoing: [String: LiveRenderer] = [:]
    private var thermalState = ProcessInfo.processInfo.thermalState
    private var screenLocked = false
    private var screenSaverRunning = false
    private var uncovered: [String: Double] = [:]
    private var failures = 0
    private var retry: DispatchWorkItem?
    private var coverageTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var powerSource: CFRunLoopSource?
    /// Held while renderers run: App Nap would stretch the coverage timer, and the sky would start
    /// moving seconds after the desktop shows. Displays and the Mac still sleep as usual.
    private var activity: NSObjectProtocol?
    private var lastCoverageCheck: Date?
    private var longestCoverageGap: TimeInterval = 0

    func start(settings: Settings) {
        self.settings = settings
        observeSystem()
        refreshPower(reconciling: false)
    }

    /// The ceiling that applies now.
    var cap: LiveCap {
        guard settings.liveEnabled else { return .still }
        return power == .adapter ? settings.liveCapOnPower : settings.liveCapOnBattery
    }

    var isHot: Bool { thermalState == .serious || thermalState == .critical }

    func update(settings: Settings) {
        self.settings = settings
        reconcile()
    }

    func setAllowed(_ allowed: Bool) {
        self.allowed = allowed
        reconcile()
    }

    /// A new wallpaper: the live sky follows it, fading each display over to the new scene.
    func show(_ scene: LiveScene, on displays: [Display]) {
        if scene != self.scene {
            failures = 0
            gaveUp = false
            failure = nil
        }
        self.scene = scene
        self.displays = displays
        reconcile()
    }

    func setDisplays(_ displays: [Display]) {
        self.displays = displays
        reconcile()
    }

    func stopAll() {
        retry?.cancel()
        retry = nil
        for renderer in Array(renderers.values) + Array(outgoing.values) { renderer.stop() }
        renderers = [:]
        outgoing = [:]
        uncovered = [:]
        coverageTimer?.invalidate()
        coverageTimer = nil
        lastCoverageCheck = nil
        updateActivity()
    }

    // MARK: Status

    /// One line for the menu, or nil when the other status lines already say enough.
    var statusLine: String? {
        guard settings.liveEnabled, allowed, scene != nil else { return nil }
        if gaveUp { return L("status.live.failed") }
        if isHot { return L("status.live.hot") }
        if cap == .still { return L("status.live.still.\(power.rawValue)") }
        let current = Array(renderers.values)
        if current.isEmpty || current.contains(where: { !$0.isLive }) { return L("status.live.starting") }
        if current.allSatisfy(\.isPaused) { return L("status.live.paused") }
        return L("status.live.running.\(power.rawValue)", cap.rawValue)
    }

    var debugInfo: [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "enabled": settings.liveEnabled,
            "capOnPower": settings.liveCapOnPower.rawValue,
            "capOnBattery": settings.liveCapOnBattery.rawValue,
            "power": power.rawValue,
            "cap": cap.rawValue,
            "allowed": allowed,
            "hot": isHot,
            "screenLocked": screenLocked,
            "screenSaver": screenSaverRunning,
            "gaveUp": gaveUp,
            "failures": failures,
            "failure": failure ?? "",
            "scene": scene.map { "\($0.weather.condition) at \(iso.string(from: $0.date))" } ?? "",
            "status": statusLine ?? "",
            "coverageCheckedSecondsAgo": lastCoverageCheck.map { (Date().timeIntervalSince($0) * 10).rounded() / 10 } ?? -1,
            "longestCoverageGapSeconds": (longestCoverageGap * 10).rounded() / 10,
            "outgoing": outgoing.values.map { Int($0.pid) },
            "renderers": renderers.values.map { renderer -> [String: Any] in
                ["display": renderer.displayName, "pid": Int(renderer.pid), "live": renderer.isLive,
                 "paused": renderer.isPaused, "cap": renderer.cap.rawValue, "fps": renderer.framesPerSecond ?? -1,
                 "uncovered": uncovered[renderer.displayID].map { ($0 * 100).rounded() / 100 } ?? -1]
            },
        ]
    }

    var diagnosticsLine: String {
        var line = "Live sky: \(settings.liveEnabled ? "on" : "off"), power \(power.rawValue), ceiling \(cap.rawValue) fps, "
            + "\(renderers.count) renderer(s)"
        let states = renderers.values.map { "\($0.displayName) \($0.isLive ? ($0.isPaused ? "paused" : "live") : "starting")" }
        if !states.isEmpty { line += " (\(states.joined(separator: ", ")))" }
        if isHot { line += ", hot" }
        if let failure { line += "; last failure: \(failure)\(gaveUp ? " (stopped until the next update)" : "")" }
        return line
    }

    // MARK: Renderers

    private func reconcile() {
        retry?.cancel()
        retry = nil
        let cap = self.cap
        guard allowed, let scene, cap != .still, !isHot, !gaveUp, !displays.isEmpty else {
            if !renderers.isEmpty || !outgoing.isEmpty {
                Log.info("live sky stopped (\(stopReason))")
                stopAll()
            }
            onChange?()
            return
        }
        let ids = Set(displays.map(\.uuid))
        for (id, renderer) in renderers where !ids.contains(id) {
            renderer.stop()
            renderers[id] = nil
        }
        for (id, renderer) in outgoing where !ids.contains(id) {
            renderer.stop()
            outgoing[id] = nil
        }
        for display in displays {
            if let renderer = renderers[display.uuid], renderer.scene == scene, renderer.frame == display.screen.frame {
                renderer.setCap(cap)
            } else {
                launch(on: display, scene: scene, cap: cap)
            }
        }
        if coverageTimer == nil {
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkCoverage() }
            }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            coverageTimer = timer
        }
        checkCoverage()
        updateActivity()
        onChange?()
    }

    private func updateActivity() {
        if renderers.isEmpty, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        } else if !renderers.isEmpty, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Pausing and resuming the live sky with the desktop")
        }
    }

    private var stopReason: String {
        if !settings.liveEnabled { return "switched off" }
        if !allowed { return "not allowed now" }
        if gaveUp { return "too many failures" }
        if isHot { return "the Mac is hot" }
        if cap == .still { return "still on \(power.rawValue)" }
        return "no scene or display"
    }

    private func launch(on display: Display, scene: LiveScene, cap: LiveCap) {
        let renderer = LiveRenderer(display: display, scene: scene, cap: cap)
        renderer.onLive = { [weak self] renderer in self?.becameLive(renderer) }
        renderer.onExit = { [weak self] renderer, reason in self?.exited(renderer, reason) }
        do {
            try renderer.start(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        } catch {
            fail("could not start the live renderer on \(display.name): \(error.localizedDescription)")
            return
        }
        if let previous = renderers[display.uuid] {
            if previous.isLive {
                outgoing.removeValue(forKey: display.uuid)?.stop()
                outgoing[display.uuid] = previous
            } else {
                previous.stop()
            }
        }
        renderers[display.uuid] = renderer
        Log.info("live sky: renderer \(renderer.pid) starting on \(display.name) (\(scene.weather.condition), ceiling \(cap.rawValue) fps)")
    }

    private func becameLive(_ renderer: LiveRenderer) {
        guard renderers[renderer.displayID] === renderer else { return }
        outgoing.removeValue(forKey: renderer.displayID)?.stop()
        failures = 0
        Log.info("live sky: renderer \(renderer.pid) is live on \(renderer.displayName)")
        checkCoverage(force: true)
    }

    private func exited(_ renderer: LiveRenderer, _ reason: String) {
        if renderers[renderer.displayID] === renderer {
            // The previous sky, if it is still running, takes the display back.
            renderers[renderer.displayID] = outgoing.removeValue(forKey: renderer.displayID)
        } else if outgoing[renderer.displayID] === renderer {
            outgoing[renderer.displayID] = nil
        }
        updateActivity()
        guard !renderer.wasStopped else { return }
        fail("renderer \(renderer.pid) on \(renderer.displayName) exited (\(reason))", details: renderer.recentOutput)
    }

    private func fail(_ message: String, details: String = "") {
        failures += 1
        failure = message
        Log.error("live sky: \(message)" + (details.isEmpty ? "" : "\n" + details))
        if failures >= 3 {
            gaveUp = true
            Log.error("live sky: stopped after \(failures) failures in a row; it tries again with the next update")
            reconcile()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10 * Double(failures), execute: work)
        onChange?()
    }

    // MARK: Pausing

    private func checkCoverage(force: Bool = false) {
        let live = renderers.values.filter(\.isLive)
        guard !live.isEmpty else { return }
        let now = Date()
        if let last = lastCoverageCheck { longestCoverageGap = max(longestCoverageGap, now.timeIntervalSince(last)) }
        lastCoverageCheck = now
        let hidden = screenLocked || screenSaverRunning
        uncovered = hidden ? [:] : DesktopCoverage.uncoveredShare(of: displays)
        var changed = force
        for renderer in live {
            let share = uncovered[renderer.displayID] ?? 0
            let pause = hidden || share < Self.pauseBelow ? true : share >= Self.resumeAt ? false : renderer.isPaused
            if pause != renderer.isPaused {
                renderer.setPaused(pause)
                changed = true
            }
        }
        if changed { onChange?() }
    }

    private func checkCoverageSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.checkCoverage() }
        }
    }

    // MARK: System

    private func observeSystem() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let layer = Unmanaged<LiveLayer>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { layer.refreshPower(reconciling: true) }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (LiveLayer) -> Void) {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self)
                }
            }
            observers.append((center, observer))
        }
        on(NotificationCenter.default, .NSProcessInfoPowerStateDidChange) { $0.refreshPower(reconciling: true) }
        on(NotificationCenter.default, ProcessInfo.thermalStateDidChangeNotification) { layer in
            let state = ProcessInfo.processInfo.thermalState
            guard state != layer.thermalState else { return }
            layer.thermalState = state
            Log.info("live sky: thermal state \(state.rawValue)")
            layer.reconcile()
        }
        let distributed = DistributedNotificationCenter.default()
        on(distributed, Notification.Name("com.apple.screenIsLocked")) { layer in
            layer.screenLocked = true
            layer.checkCoverage()
        }
        on(distributed, Notification.Name("com.apple.screenIsUnlocked")) { layer in
            layer.screenLocked = false
            layer.checkCoverage()
        }
        on(distributed, Notification.Name("com.apple.screensaver.didstart")) { layer in
            layer.screenSaverRunning = true
            layer.checkCoverage()
        }
        on(distributed, Notification.Name("com.apple.screensaver.didstop")) { layer in
            layer.screenSaverRunning = false
            layer.checkCoverage()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        on(workspace, NSWorkspace.didActivateApplicationNotification) { $0.checkCoverageSoon() }
        on(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.checkCoverageSoon() }
    }

    private func refreshPower(reconciling: Bool) {
        let power: Power
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            power = .lowPower
        } else if Self.onBattery {
            power = .battery
        } else {
            power = .adapter
        }
        guard power != self.power else { return }
        self.power = power
        Log.info("live sky: power \(power.rawValue)")
        if reconciling { reconcile() }
    }

    private static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}

/// How much of each desktop is showing: the share of the display below the menu bar that no
/// ordinary window covers (window levels from normal windows up to, not including, the Dock).
enum DesktopCoverage {
    static func uncoveredShare(of displays: [Display]) -> [String: Double] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [:] }
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        var windows: [CGRect] = []
        var owners: Set<Int32> = []
        for window in list {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer >= 0, layer < dockLevel,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 40, rect.height >= 40 else { continue }
            windows.append(rect)
            if layer == 0, let owner = window[kCGWindowOwnerPID as String] as? Int32 { owners.insert(owner) }
        }
        // Clicking the wallpaper to reveal the desktop moves the windows aside, but the window list
        // may still report them in place. It does make Finder the active app, with none of its own
        // windows on screen: the desktop is what's being looked at.
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == "com.apple.finder",
           !owners.contains(front.processIdentifier) {
            return Dictionary(uniqueKeysWithValues: displays.map { ($0.uuid, 1.0) })
        }
        var shares: [String: Double] = [:]
        for display in displays {
            // Window bounds use the same top-left global coordinates as CGDisplayBounds.
            var area = CGDisplayBounds(display.id)
            let menuBar = max(0, display.screen.frame.maxY - display.screen.visibleFrame.maxY)
            area.origin.y += menuBar
            area.size.height -= menuBar
            shares[display.uuid] = uncoveredShare(of: area, under: windows.filter { $0.intersects(area) })
        }
        return shares
    }

    /// Samples a 64 × 40 grid of points over the area.
    private static func uncoveredShare(of area: CGRect, under windows: [CGRect]) -> Double {
        guard area.width > 0, area.height > 0 else { return 0 }
        let columns = 64, rows = 40
        var showing = 0
        for row in 0..<rows {
            let y = area.minY + (CGFloat(row) + 0.5) * area.height / CGFloat(rows)
            for column in 0..<columns {
                let point = CGPoint(x: area.minX + (CGFloat(column) + 0.5) * area.width / CGFloat(columns), y: y)
                if !windows.contains(where: { $0.contains(point) }) { showing += 1 }
            }
        }
        return Double(showing) / Double(columns * rows)
    }
}

/// One `LiveSkyRenderer --live` process drawing one display's sky. It reads "fps <n>", "pause" and
/// "resume" on standard input and exits when that pipe closes.
@MainActor
final class LiveRenderer {
    let displayID: String
    let displayName: String
    let frame: CGRect
    let scene: LiveScene
    private(set) var cap: LiveCap
    private(set) var isLive = false
    private(set) var isPaused = false
    private(set) var framesPerSecond: Double?
    private(set) var wasStopped = false
    var onLive: ((LiveRenderer) -> Void)?
    var onExit: ((LiveRenderer, String) -> Void)?

    private let process = Process()
    private var input: FileHandle?
    private var output: [String] = []

    var pid: Int32 { process.processIdentifier }
    /// The renderer's last lines, for the log when it fails.
    var recentOutput: String { output.suffix(30).joined(separator: "\n") }

    init(display: Display, scene: LiveScene, cap: LiveCap) {
        displayID = display.uuid
        displayName = display.name
        frame = display.screen.frame
        self.scene = scene
        self.cap = cap
    }

    func start(reduceMotion: Bool) throws {
        var arguments = RendererRunner.weatherArguments(scene.weather, date: scene.date)
        let frameText = [frame.minX, frame.minY, frame.width, frame.height].map { String(Double($0)) }.joined(separator: ",")
        arguments += ["--live", "--frame", frameText, "--fps", String(cap.rendererFPS)]
        if reduceMotion { arguments.append("--reduce-motion") }
        process.executableURL = Paths.renderer
        process.arguments = arguments
        let inputPipe = Pipe(), outputPipe = Pipe(), errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        read(outputPipe)
        read(errorPipe)
        // Holds the renderer until its process has exited, so the exit is always reported.
        process.terminationHandler = { process in
            let reason = process.terminationReason == .uncaughtSignal
                ? "signal \(process.terminationStatus)" : "exit \(process.terminationStatus)"
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.exited(reason) }
            }
        }
        try process.run()
        input = inputPipe.fileHandleForWriting
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        send(paused ? "pause" : "resume")
    }

    func setCap(_ cap: LiveCap) {
        guard cap != self.cap else { return }
        self.cap = cap
        send("fps \(cap.rendererFPS)")
    }

    /// Closing its input ends the renderer; it is terminated if it doesn't exit by itself.
    func stop() {
        guard !wasStopped else { return }
        wasStopped = true
        try? input?.close()
        input = nil
        let process = self.process
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func send(_ command: String) {
        guard let input else { return }
        do {
            try input.write(contentsOf: Data((command + "\n").utf8))
        } catch {
            Log.error("live sky: renderer \(pid) did not take \"\(command)\": \(error.localizedDescription)")
        }
    }

    private func read(_ pipe: Pipe) {
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let lines = buffer.append(data)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.received(lines) }
            }
        }
    }

    private func received(_ lines: [String]) {
        for line in lines {
            if line.hasPrefix("LIVESKY_LIVE ") {
                framesPerSecond = Self.object(line.dropFirst("LIVESKY_LIVE ".count))?["fps"] as? Double
                continue
            }
            output.append(line)
            if output.count > 60 { output.removeFirst(output.count - 60) }
            if line.hasPrefix("LIVESKY_STATUS "), !isLive,
               Self.object(line.dropFirst("LIVESKY_STATUS ".count))?["status"] as? String == "live" {
                isLive = true
                onLive?(self)
            }
        }
    }

    private func exited(_ reason: String) {
        input = nil
        onExit?(self, reason)
    }

    private static func object(_ json: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }
}

/// Splits a pipe's output into complete lines.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let end = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<end], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...end)
        }
        return lines
    }
}
