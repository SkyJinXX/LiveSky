import AppKit
import Combine
import CoreLocation

/// Owns the settings, the schedule and the update pipeline:
/// location -> Open-Meteo -> WeatherUI renderer -> validation -> per-display PNG -> wallpaper.
@MainActor
final class LiveSkyController: ObservableObject {
    enum Reason: String {
        case launch, timer, user, retry, wake, screens, settings, resume
        /// Started by the user: bypasses the incompatibility back-off and display-sleep checks.
        var isUserInitiated: Bool { self == .user || self == .retry }
    }

    @Published private(set) var settings: Settings
    @Published private(set) var state: AppState
    @Published private(set) var isUpdating = false
    @Published private(set) var transientError: String?
    @Published private(set) var notice: String?
    @Published private(set) var locationAuthorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var loginItemNote: String?
    @Published private(set) var nextUpdate: Date?
    @Published private(set) var currentPlaceName: String?
    /// Counts finished update attempts (debug control waits on it).
    private(set) var completedUpdates = 0

    let location = LocationService()
    let wallpapers = WallpaperManager()
    private let renderer = RendererRunner()
    let live = LiveLayer()
    private var timer: Timer?
    private var pendingWork: [String: DispatchWorkItem] = [:]
    private var observers: [NSObjectProtocol] = []
    private var displaysAsleep = false
    private var sessionActive = true
    /// Bumped by sleep, wake and session changes; a render that spans one is discarded, not failed.
    private var sleepEpoch = 0
    /// Bumped by pause, restore and quit; an update in flight then stops without side effects.
    private var generation = 0
    private var missedWhileAsleep = false
    private var queuedReason: Reason?
    private var transientFailures = 0

    init() {
        Paths.prepare()
        settings = JSONStore.load(Settings.self, from: Paths.settings) ?? Settings()
        state = JSONStore.load(AppState.self, from: Paths.state) ?? AppState()
        locationAuthorization = location.authorization
        location.onAuthorizationChange = { [weak self] in self?.authorizationChanged() }
        currentPlaceName = state.lastWeather?.placeName
        live.onChange = { [weak self] in self?.objectWillChange.send() }
    }

    var isVerifiedBuild: Bool { SystemInfo.isVerified && !settings.debug.pretendUnverified }

    // MARK: Lifecycle

    func start() {
        observeSystem()
        displaysAsleep = Displays.anyAsleep
        live.start(settings: settings)
        if settings.setupComplete {
            applyLoginItem(onLaunch: true)
            if settings.paused {
                Log.info("started paused")
            } else {
                showLastSceneIfFresh()
                requestUpdate(.launch, after: 2)
            }
        }
        refreshLive()
        Log.info("LiveSky \(SystemInfo.appVersion) started on \(SystemInfo.versionDescription), verified: \(SystemInfo.isVerified)")
    }

    func shutdown() {
        generation += 1
        renderer.cancel()
        live.stopAll()
        save()
    }

    // MARK: Settings

    func completeSetup(mode: LocationMode, place: Place?, intervalMinutes: Int, launchAtLogin: Bool) {
        settings.locationMode = mode
        if let place { settings.manualPlace = place }
        settings.intervalMinutes = intervalMinutes
        settings.launchAtLogin = launchAtLogin
        settings.setupComplete = true
        settings.paused = false
        saveSettings()
        refreshLive()
        applyLoginItem()
        if mode == .system { location.requestAuthorization() }
        Log.info("setup complete: \(mode.rawValue), every \(intervalMinutes) min")
        requestUpdate(.user)
    }

    func setLocationMode(_ mode: LocationMode) {
        guard settings.locationMode != mode else { return }
        settings.locationMode = mode
        saveSettings()
        if mode == .system { location.requestAuthorization() }
        if settings.setupComplete { requestUpdate(.settings) }
    }

    func setManualPlace(_ place: Place) {
        settings.manualPlace = place
        settings.locationMode = .manual
        saveSettings()
        Log.info("city set to \(place.displayName)")
        if settings.setupComplete { requestUpdate(.settings) }
    }

    func setInterval(_ minutes: Int) {
        guard Settings.intervals.contains(minutes), minutes != settings.intervalMinutes else { return }
        settings.intervalMinutes = minutes
        saveSettings()
        if !isUpdating { scheduleTimer() }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        settings.launchAtLogin = enabled
        saveSettings()
        applyLoginItem()
    }

    func setLiveEnabled(_ enabled: Bool) {
        guard settings.liveEnabled != enabled else { return }
        settings.liveEnabled = enabled
        saveSettings()
        Log.info("live sky switched \(enabled ? "on" : "off")")
        live.update(settings: settings)
    }

    func setLiveCap(_ cap: LiveCap, onBattery: Bool) {
        guard (onBattery ? settings.liveCapOnBattery : settings.liveCapOnPower) != cap else { return }
        if onBattery { settings.liveCapOnBattery = cap } else { settings.liveCapOnPower = cap }
        saveSettings()
        Log.info("live sky ceiling \(onBattery ? "on battery" : "on power adapter"): \(cap.rawValue == 0 ? "still" : "\(cap.rawValue) fps")")
        live.update(settings: settings)
    }

    /// Registers or removes the login item. On launch it only acts when the app was moved since
    /// it registered (so the login item follows the app) or the registration went missing.
    private func applyLoginItem(onLaunch: Bool = false) {
        let path = Bundle.main.bundlePath
        if onLaunch, settings.launchAtLogin, settings.loginItemPath != nil, settings.loginItemPath != path {
            Log.info("app moved from \(settings.loginItemPath ?? "-"); registering the login item again")
            LoginItem.apply(false)
        }
        loginItemNote = LoginItem.apply(settings.launchAtLogin)
        let recorded = settings.launchAtLogin ? path : nil
        if settings.loginItemPath != recorded {
            settings.loginItemPath = recorded
            saveSettings()
        }
    }

    func setDebug(_ change: (inout DebugOptions) -> Void) {
        change(&settings.debug)
        saveSettings()
        if !isUpdating { scheduleTimer() }
    }

    // MARK: Menu actions

    func updateNow() { requestUpdate(.user) }

    /// Debug control only: behave as if the display layout changed since the last update.
    func simulateScreenChange() {
        state.appliedSignature = "simulated-change"
        screensChanged()
    }

    /// Debug control only: forget a recorded renderer failure without rendering.
    func clearFailureForTesting() {
        state.failure = nil
        save()
        refreshLive()
    }
    func retry() { requestUpdate(.retry) }

    func pause() {
        guard !settings.paused else { return }
        settings.paused = true
        saveSettings()
        cancelInFlight()
        refreshLive()
        notice = nil
        Log.info("paused")
    }

    func resume() {
        guard settings.paused else { return }
        settings.paused = false
        saveSettings()
        wallpapers.refreshBackupsAfterPause(Displays.current())
        state.restored = false
        notice = nil
        save()
        refreshLive()
        Log.info("resumed")
        requestUpdate(.resume)
    }

    func restoreOriginalWallpaper() {
        settings.paused = true
        saveSettings()
        cancelInFlight()
        let result = wallpapers.restore(Displays.current())
        state.restored = true
        save()
        refreshLive()
        if !result.missing.isEmpty {
            notice = L("notice.restoreMissing", result.missing.joined(separator: ", "))
        } else if !result.failed.isEmpty {
            notice = L("notice.restoreFailed", result.failed.joined(separator: ", "))
        } else if result.restored.isEmpty {
            notice = L("notice.nothingToRestore")
        } else {
            notice = nil // the paused status line already says the original is back
        }
        Log.info("restore: \(result.restored.count) restored, \(result.missing.count) missing, \(result.failed.count) failed")
    }

    private func cancelInFlight() {
        generation += 1
        pendingWork["update"]?.cancel()
        queuedReason = nil
        timer?.invalidate()
        timer = nil
        nextUpdate = nil
        renderer.cancel()
    }

    // MARK: Scheduling

    func requestUpdate(_ reason: Reason, after delay: TimeInterval = 0) {
        pendingWork["update"]?.cancel()
        if delay > 0 {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.requestUpdate(reason) }
            }
            pendingWork["update"] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return
        }
        if isUpdating {
            if queuedReason != .settings && queuedReason != .screens { queuedReason = reason }
            return
        }
        Task { await self.update(reason) }
    }

    private func scheduleTimer(after seconds: TimeInterval? = nil) {
        timer?.invalidate()
        timer = nil
        nextUpdate = nil
        guard settings.setupComplete, !settings.paused else { return }
        let interval = seconds ?? settings.updateInterval
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired() }
        }
        timer.tolerance = min(30, interval * 0.05)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        nextUpdate = Date().addingTimeInterval(interval)
    }

    private func timerFired() {
        timer = nil
        nextUpdate = nil
        if displaysAsleep || !sessionActive {
            missedWhileAsleep = true
            Log.info("scheduled update skipped: displays asleep or session inactive")
            scheduleTimer()
            return
        }
        requestUpdate(.timer)
    }

    /// After a renderer failure, automatic attempts wait for a different macOS build and happen
    /// at most once a day; the user can always press Retry.
    private var automaticRenderAllowed: Bool {
        guard let failure = state.failure else { return true }
        return failure.osBuild != SystemInfo.osBuild && Date().timeIntervalSince(failure.date) >= 86_400
    }

    // MARK: Update pipeline

    private func update(_ reason: Reason) async {
        guard settings.setupComplete, !settings.paused else { return }
        if !reason.isUserInitiated {
            if displaysAsleep || !sessionActive {
                missedWhileAsleep = true
                Log.info("\(reason.rawValue) update skipped: displays asleep or session inactive")
                scheduleTimer()
                return
            }
            if !automaticRenderAllowed {
                Log.info("\(reason.rawValue) update skipped after a renderer failure: waiting for Retry, or a new macOS build at most once a day")
                scheduleTimer()
                return
            }
        }
        guard !AppLocation.isTranslocated else {
            transientError = L("error.translocated")
            return
        }
        isUpdating = true
        notice = nil
        // Keep App Nap from throttling LiveSky while it waits for the renderer.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Updating the LiveSky wallpaper")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let generation = self.generation
        let epoch = sleepEpoch
        Log.info("update started (\(reason.rawValue))")
        defer {
            isUpdating = false
            completedUpdates += 1
            // The update that just ran covers queued timer, wake and user requests; only a new
            // location or display layout needs another pass.
            if let queued = queuedReason {
                queuedReason = nil
                if queued == .settings || queued == .screens { requestUpdate(queued) }
            }
        }
        do {
            let displays = Displays.current()
            guard !displays.isEmpty else { throw LiveSkyError.wallpaper(L("error.noDisplays")) }
            if reason == .screens, let source = reusableSource() {
                let applied = try applyToDisplays(source, startedWith: displays)
                save()
                live.setDisplays(applied)
                scheduleTimer(after: max(60, settings.updateInterval - Date().timeIntervalSince(state.lastSourceDate ?? Date())))
                Log.info("re-composed the last render for the new display layout")
                return
            }

            let weather = try await fetchWeather()
            guard generation == self.generation else { return }
            currentPlaceName = weather.placeName
            state.lastAttempt = Date()
            state.lastAttemptBuild = SystemInfo.osBuild

            let renderURL = Paths.renders.appendingPathComponent("render-\(Self.fileStamp()).png")
            let job = RenderJob(weather: weather, date: Date(), output: renderURL,
                                simulateIncompatible: settings.debug.simulateIncompatible,
                                simulateCrash: settings.debug.simulateCrash)
            let outcome = await renderer.render(job)
            guard generation == self.generation else {
                try? FileManager.default.removeItem(at: renderURL)
                Log.info("update cancelled")
                return
            }
            switch outcome {
            case .failure(let failure):
                try? FileManager.default.removeItem(at: renderURL)
                if epoch != sleepEpoch || displaysAsleep || !sessionActive {
                    Log.info("render interrupted by sleep (\(failure.kind)); will update after wake")
                    missedWhileAsleep = true
                    return
                }
                recordFailure(failure)
                return
            case .success(let result):
                let source: CGImage
                switch ImageTools.loadValidatedSource(result.output) {
                case .failure(let problem):
                    if epoch != sleepEpoch || displaysAsleep || !sessionActive {
                        Log.info("render interrupted by sleep (\(problem.check)); will update after wake")
                        missedWhileAsleep = true
                        try? FileManager.default.removeItem(at: renderURL)
                        return
                    }
                    let kept = Paths.renders.appendingPathComponent("rejected-\(renderURL.lastPathComponent)")
                    try? FileManager.default.removeItem(at: kept)
                    try? FileManager.default.moveItem(at: renderURL, to: kept)
                    recordFailure(FailureRecord(kind: "image", check: problem.check, detail: problem.detail, stage: "validation",
                                                osVersion: SystemInfo.osVersion, osBuild: SystemInfo.osBuild, date: Date(),
                                                exitDescription: "exit 0", stdout: "", stderr: "rejected render kept at \(kept.path)"))
                    return
                case .success(let image):
                    source = image
                }
                let applied = try applyToDisplays(source, startedWith: displays)
                state.failure = nil
                state.lastSuccess = Date()
                state.lastSuccessBuild = SystemInfo.osBuild
                state.lastWeather = weather
                state.lastSunElevation = result.sunElevation
                state.lastSourcePath = result.output.path
                state.lastSourceDate = Date()
                state.lastSourcePlace = placeKey
                pruneRenders(keep: result.output.path)
                transientError = nil
                transientFailures = 0
                save()
                Log.info("update finished: \(weather.condition), \(applied.count) display(s)")
                // This update may have cleared a renderer failure, which kept the live sky off.
                refreshLive()
                live.show(LiveScene(weather: weather, date: job.date), on: applied)
                scheduleTimer()
            }
        } catch {
            guard generation == self.generation else { return }
            let message: String
            switch error as? LiveSkyError {
            case .network(let detail)?: message = L("error.network", detail)
            case .wallpaper(let detail)?: message = L("error.wallpaper", detail)
            default: message = error.localizedDescription
            }
            transientError = message
            transientFailures += 1
            // Back off 1, 2, 4 … minutes, never longer than the chosen interval.
            let delay = min(settings.updateInterval, 60 * pow(2, Double(min(transientFailures - 1, 6))))
            Log.error("update failed (\(reason.rawValue)): \(message); next attempt in \(Int(delay)) s")
            scheduleTimer(after: delay)
        }
    }

    private func recordFailure(_ failure: FailureRecord) {
        state.failure = failure
        transientError = nil
        save()
        refreshLive()
        Log.error("renderer failure on \(failure.osBuild): \(failure.kind) \(failure.check) \(failure.detail) [stage \(failure.stage), \(failure.exitDescription)]")
        scheduleTimer()
    }

    private var placeKey: String {
        settings.locationMode == .manual ? "manual:\(settings.manualPlace?.displayName ?? "")" : "system"
    }

    private func reusableSource() -> CGImage? {
        guard let path = state.lastSourcePath, let date = state.lastSourceDate, state.lastSourcePlace == placeKey,
              Date().timeIntervalSince(date) < settings.updateInterval,
              case .success(let image) = ImageTools.loadValidatedSource(URL(fileURLWithPath: path)) else { return nil }
        return image
    }

    private func fetchWeather() async throws -> WeatherSnapshot {
        let client = OpenMeteo(simulateOffline: settings.debug.simulateOffline)
        switch settings.locationMode {
        case .manual?:
            guard let place = settings.manualPlace else { throw LiveSkyError.location(L("error.location.noCity")) }
            return try await client.weather(latitude: place.latitude, longitude: place.longitude,
                                            timeZone: place.timeZone, placeName: place.name)
        case .system?:
            guard location.servicesEnabled else { throw LiveSkyError.location(L("error.location.disabled")) }
            let found = try await location.currentLocation()
            let name = await location.placeName(for: found)
            return try await client.weather(latitude: found.coordinate.latitude, longitude: found.coordinate.longitude,
                                            timeZone: nil, placeName: name)
        case nil:
            throw LiveSkyError.location(L("error.location.notChosen"))
        }
    }

    /// Sets the render on the displays found when the update started, and again on the displays
    /// there are now if some came or went while it rendered. Waking from sleep often brings an
    /// external display back a few seconds into the update; it would otherwise keep the old sky
    /// until the next update, since its return can look like no change at all. Returns the displays
    /// that have the render.
    private func applyToDisplays(_ source: CGImage, startedWith displays: [Display]) throws -> [Display] {
        try apply(source, to: displays)
        let current = Displays.current()
        guard !current.isEmpty, Displays.signature(current) != Displays.signature(displays) else { return displays }
        Log.info("displays changed during the update: \(Displays.signature(current))")
        try apply(source, to: current)
        return current
    }

    /// Writes one new file per display (macOS caches wallpapers by path), then sets them all.
    private func apply(_ source: CGImage, to displays: [Display]) throws {
        let stamp = Self.fileStamp()
        var prepared: [(Display, URL)] = []
        for display in displays {
            guard let composed = ImageTools.compose(source, width: display.pixelWidth, height: display.pixelHeight) else {
                throw LiveSkyError.wallpaper("could not compose \(display.pixelWidth) × \(display.pixelHeight)")
            }
            let url = Paths.wallpapers.appendingPathComponent("wallpaper-\(display.uuid)-\(stamp).png")
            try ImageTools.writePNG(composed, to: url)
            prepared.append((display, url))
        }
        for (display, url) in prepared {
            let previous = NSWorkspace.shared.desktopImageURL(for: display.screen)?.path
            wallpapers.backUpIfNeeded(display)
            do {
                try wallpapers.set(url, on: display)
            } catch {
                throw LiveSkyError.wallpaper(error.localizedDescription)
            }
            state.applied[display.uuid] = url.path
            wallpapers.prune(display.uuid, keep: Set([url.path, previous].compactMap { $0 }))
            Log.info("set \(display.name) (\(display.pixelWidth) × \(display.pixelHeight)) to \(url.lastPathComponent)")
        }
        state.appliedSignature = Displays.signature(displays)
    }

    private func pruneRenders(keep: String) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: Paths.renders.path)) ?? [])
            .filter { $0.hasPrefix("render-") && $0.hasSuffix(".png") }
            .sorted()
        for name in names.dropLast(2) {
            let path = Paths.renders.appendingPathComponent(name).path
            if path != keep { try? FileManager.default.removeItem(atPath: path) }
        }
    }

    static func fileStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }

    // MARK: System events

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (LiveSkyController) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self)
                }
            })
        }
        on(workspace, NSWorkspace.screensDidSleepNotification) { controller in
            controller.displaysAsleep = true
            controller.sleepEpoch += 1
            Log.info("displays asleep")
            controller.refreshLive()
        }
        on(workspace, NSWorkspace.willSleepNotification) { controller in
            controller.displaysAsleep = true
            controller.sleepEpoch += 1
            Log.info("system going to sleep")
            controller.refreshLive()
        }
        on(workspace, NSWorkspace.screensDidWakeNotification) { controller in
            controller.displaysAsleep = false
            controller.sleepEpoch += 1
            Log.info("displays awake")
            controller.refreshLive()
            controller.updateAfterWake()
        }
        on(workspace, NSWorkspace.didWakeNotification) { controller in
            controller.sleepEpoch += 1
            controller.displaysAsleep = Displays.anyAsleep
            Log.info("system woke, displays asleep: \(controller.displaysAsleep)")
            controller.refreshLive()
            if !controller.displaysAsleep { controller.updateAfterWake() }
        }
        on(workspace, NSWorkspace.sessionDidResignActiveNotification) { controller in
            controller.sessionActive = false
            controller.sleepEpoch += 1
            Log.info("session inactive")
            controller.refreshLive()
        }
        on(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { controller in
            controller.sessionActive = true
            controller.sleepEpoch += 1
            Log.info("session active")
            controller.refreshLive()
            controller.updateAfterWake()
        }
        on(workspace, NSWorkspace.activeSpaceDidChangeNotification) { controller in
            controller.debounce("space", 1) { $0.spaceChanged() }
        }
        on(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { controller in
            controller.debounce("screens", 2) { $0.screensChanged() }
        }
    }

    private func debounce(_ key: String, _ delay: TimeInterval, _ action: @escaping @MainActor (LiveSkyController) -> Void) {
        pendingWork[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        pendingWork[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func updateAfterWake() {
        guard settings.setupComplete, !settings.paused, !displaysAsleep, sessionActive else { return }
        let stale = state.lastSuccess.map { Date().timeIntervalSince($0) >= 60 } ?? true
        if missedWhileAsleep || stale {
            missedWhileAsleep = false
            requestUpdate(.wake, after: 5)
        }
    }

    private func screensChanged() {
        guard settings.setupComplete else { return }
        let displays = Displays.current()
        // A display that only moved keeps its wallpaper, but its live window has to follow.
        live.setDisplays(displays)
        if state.restored {
            // A display that was away during "Restore Original Wallpaper" gets its original back too.
            let stillOurs = displays.filter { Paths.isLiveSkyWallpaper(NSWorkspace.shared.desktopImageURL(for: $0.screen)) }
            if !stillOurs.isEmpty { _ = wallpapers.restore(stillOurs) }
            return
        }
        guard !settings.paused, Displays.signature(displays) != state.appliedSignature else { return }
        Log.info("display layout changed: \(Displays.signature(displays))")
        requestUpdate(.screens)
    }

    /// A Space that still shows an older picture (for example one created after the last
    /// update) gets the current LiveSky wallpaper again.
    private func spaceChanged() {
        guard settings.setupComplete, !settings.paused, !state.restored, !isUpdating else { return }
        for display in Displays.current() {
            guard let applied = state.applied[display.uuid], FileManager.default.fileExists(atPath: applied),
                  let current = NSWorkspace.shared.desktopImageURL(for: display.screen),
                  current.path != applied else { continue }
            do {
                try wallpapers.set(URL(fileURLWithPath: applied), on: display)
                Log.info("re-applied the wallpaper on a Space that showed \(current.lastPathComponent)")
            } catch {
                Log.error("could not re-apply the wallpaper: \(error)")
            }
        }
    }

    private func authorizationChanged() {
        locationAuthorization = location.authorization
        Log.info("location authorization: \(location.authorization.rawValue)")
        if settings.setupComplete, !settings.paused, settings.locationMode == .system, location.isAuthorized,
           state.lastSuccess == nil || transientError != nil {
            requestUpdate(.settings, after: 1)
        }
    }

    // MARK: Live sky

    /// The live sky runs only while the wallpaper under it is kept up to date and can be seen.
    private var liveAllowed: Bool {
        settings.setupComplete && !settings.paused && !state.restored && state.failure == nil && !displaysAsleep && sessionActive
    }

    private func refreshLive() { live.setAllowed(liveAllowed) }

    /// At launch the live sky starts from the last render if it is recent, while the first update runs.
    private func showLastSceneIfFresh() {
        guard let weather = state.lastWeather, let date = state.lastSourceDate, state.failure == nil, !state.restored,
              state.lastSourcePlace == placeKey, Date().timeIntervalSince(date) < settings.updateInterval else { return }
        live.show(LiveScene(weather: weather, date: date), on: Displays.current())
    }

    // MARK: Persistence

    private func save() { JSONStore.save(state, to: Paths.state) }
    private func saveSettings() { JSONStore.save(settings, to: Paths.settings) }
}
