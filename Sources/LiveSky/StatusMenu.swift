import AppKit
import Combine

extension LiveSkyController {
    /// The status shown at the top of the menu.
    var statusLines: [String] {
        guard settings.setupComplete else { return [L("status.setup")] }
        var lines: [String] = []
        if state.failure != nil {
            // Short and plain here; the failing check and renderer output go to Export Diagnostics.
            lines.append(L("status.incompatible"))
            lines.append(L("status.incompatible.detail"))
            if settings.paused { lines.append(state.restored ? L("status.restored") : L("status.paused")) }
            return lines
        }
        if AppLocation.isTranslocated { lines.append(L("error.translocated")) }
        if let weather = state.lastWeather {
            var line = "\(weather.placeName) · \(L("condition.\(weather.condition)"))"
            if let celsius = weather.temperatureCelsius {
                // Converted to the user's preferred unit (°F in the US), shown as "81°".
                line += " · " + Measurement(value: celsius, unit: UnitTemperature.celsius).formatted(
                    .measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))
            }
            lines.append(line)
        } else if let name = currentPlaceName {
            lines.append(name)
        }
        if isUpdating {
            lines.append(L("status.updating"))
        } else if let last = state.lastSuccess {
            lines.append(L("status.lastUpdate", Self.time(last)))
        } else {
            lines.append(L("status.notYet"))
        }
        if let error = transientError {
            lines.append(error)
            if let next = nextUpdate, !settings.paused { lines.append(L("status.nextRetry", Self.time(next))) }
        }
        if let line = live.statusLine { lines.append(line) }
        if let notice { lines.append(notice) }
        if settings.paused {
            lines.append(state.restored ? L("status.restored") : L("status.paused"))
        }
        return lines
    }

    /// One readable sentence about a renderer failure, for the diagnostics report.
    static func describe(_ failure: FailureRecord) -> String {
        switch failure.kind {
        case "check": return L("failure.check", "\(failure.check): \(failure.detail)")
        case "crash": return L("failure.crash", failure.detail, failure.stage)
        case "killed": return L("failure.killed", failure.detail)
        case "timeout": return L("failure.timeout", failure.stage)
        case "image": return L("failure.image", "\(failure.check): \(failure.detail)")
        case "launch": return L("failure.launch", failure.detail)
        default: return L("failure.other", failure.detail)
        }
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Filled SF Symbols that follow the current weather, day or night.
    var statusSymbol: String {
        if state.failure != nil { return "exclamationmark.triangle.fill" }
        if settings.paused { return "pause.circle.fill" }
        guard let weather = state.lastWeather else { return "cloud.sun.fill" }
        let day = (state.lastSunElevation ?? 1) > 0
        switch weather.condition {
        case "clear", "mostlyClear": return day ? "sun.max.fill" : "moon.stars.fill"
        case "partlyCloudy": return day ? "cloud.sun.fill" : "cloud.moon.fill"
        case "cloudy": return "cloud.fill"
        case "foggy": return "cloud.fog.fill"
        case "drizzle": return "cloud.drizzle.fill"
        case "rain": return "cloud.rain.fill"
        case "heavyRain": return "cloud.heavyrain.fill"
        case "freezingDrizzle", "freezingRain": return "cloud.sleet.fill"
        case "snow", "heavySnow": return "cloud.snow.fill"
        case "thunderstorms", "strongStorms": return "cloud.bolt.rain.fill"
        default: return "cloud.sun.fill"
        }
    }
}

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let controller: LiveSkyController
    private let showSettings: () -> Void
    private var subscription: AnyCancellable?
    private var isOpen = false

    init(controller: LiveSkyController, showSettings: @escaping () -> Void) {
        self.controller = controller
        self.showSettings = showSettings
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.toolTip = "LiveSky"
        refresh()
        subscription = controller.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        let image = NSImage(systemSymbolName: controller.statusSymbol, accessibilityDescription: "LiveSky")
        image?.isTemplate = true
        statusItem.button?.image = image
        if isOpen { rebuild() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }
    func menuDidClose(_ menu: NSMenu) { isOpen = false }

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        guard let seconds = autoCloseAfter else { return }
        autoCloseAfter = nil
        // Menu tracking runs its own run loop mode, which the main queue does not service.
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.menu.cancelTracking() }
        }
        let current = RunLoop.current.currentMode
        Log.info("menu opened in run loop mode \(current?.rawValue ?? "none")")
        for mode in [current, .common, .eventTracking].compactMap({ $0 }) {
            RunLoop.current.add(timer, forMode: mode)
        }
    }

    private var autoCloseAfter: TimeInterval?

    /// Debug control: shows the status menu near the top of the main screen (the status item
    /// itself may be hidden by a menu bar manager) and closes it after `seconds`.
    func open(closeAfter seconds: TimeInterval) {
        autoCloseAfter = seconds
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let point = NSPoint(x: screen.frame.midX - 130, y: screen.visibleFrame.maxY - 8)
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    /// Menu item titles for debug control (status lines are a custom view and come first).
    var itemTitles: [String] {
        if !isOpen { rebuild() }
        return menu.items.map { $0.isSeparatorItem ? "—" : ($0.view != nil ? "[status]" : $0.title) }
    }

    private func rebuild() {
        menu.removeAllItems()
        let settings = controller.settings
        menu.addItem(statusItem(controller.statusLines))
        menu.addItem(.separator())
        let busy = controller.isUpdating
        if controller.state.failure != nil {
            add(L("menu.retry"), #selector(retry), enabled: settings.setupComplete && !settings.paused && !busy)
            add(L("menu.exportDiagnostics"), #selector(exportDiagnostics))
        } else {
            add(L("menu.updateNow"), #selector(updateNow), enabled: settings.setupComplete && !settings.paused && !busy)
        }
        add(settings.paused ? L("menu.resume") : L("menu.pause"), #selector(togglePause), enabled: settings.setupComplete)
        add(L("menu.restore"), #selector(restore), enabled: controller.wallpapers.hasBackups && !(settings.paused && controller.state.restored))
        menu.addItem(.separator())
        add(L("menu.live"), #selector(toggleLive), enabled: settings.setupComplete).state = settings.liveEnabled ? .on : .off
        let capsEnabled = settings.setupComplete && settings.liveEnabled
        menu.addItem(capItem(L("menu.live.onPower", settings.liveCapOnPower.title), selected: settings.liveCapOnPower,
                             onBattery: false, enabled: capsEnabled))
        menu.addItem(capItem(L("menu.live.onBattery", settings.liveCapOnBattery.title), selected: settings.liveCapOnBattery,
                             onBattery: true, enabled: capsEnabled))
        menu.addItem(.separator())
        add(L("menu.settings"), #selector(openSettings), key: ",")
        add(L("menu.quit"), #selector(quit), key: "q")
    }

    /// The status block at the top: the first line as a headline, details below, wrapped.
    private func statusItem(_ lines: [String]) -> NSMenuItem {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        for (index, line) in lines.enumerated() {
            let label = NSTextField(wrappingLabelWithString: line)
            label.isSelectable = false
            label.preferredMaxLayoutWidth = 290
            if index == 0 {
                label.font = NSFont.menuFont(ofSize: 0).withWeight(.semibold)
                label.textColor = .labelColor
            } else {
                label.font = NSFont.menuFont(ofSize: NSFont.systemFontSize - 1)
                label.textColor = .secondaryLabelColor
            }
            stack.addArrangedSubview(label)
        }
        let size = stack.fittingSize
        stack.frame = NSRect(x: 0, y: 0, width: max(size.width, 240), height: size.height)
        let item = NSMenuItem()
        item.view = stack
        item.toolTip = lines.joined(separator: "\n")
        return item
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }

    /// "On Power Adapter: Up to 60 fps" with the ceilings in a submenu. The tag carries the
    /// ceiling, plus 1000 for the battery setting.
    private func capItem(_ title: String, selected: LiveCap, onBattery: Bool, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.indentationLevel = 1
        item.isEnabled = enabled
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for cap in LiveCap.allCases {
            let choice = NSMenuItem(title: cap.title, action: #selector(chooseCap(_:)), keyEquivalent: "")
            choice.target = self
            choice.tag = cap.rawValue + (onBattery ? 1000 : 0)
            choice.state = cap == selected ? .on : .off
            submenu.addItem(choice)
        }
        item.submenu = submenu
        return item
    }

    @objc private func updateNow() { controller.updateNow() }
    @objc private func retry() { controller.retry() }
    @objc private func togglePause() { controller.settings.paused ? controller.resume() : controller.pause() }
    @objc private func restore() { controller.restoreOriginalWallpaper() }
    @objc private func toggleLive() { controller.setLiveEnabled(!controller.settings.liveEnabled) }
    @objc private func chooseCap(_ sender: NSMenuItem) {
        guard let cap = LiveCap(rawValue: sender.tag % 1000) else { return }
        controller.setLiveCap(cap, onBattery: sender.tag >= 1000)
    }
    @objc private func exportDiagnostics() { Diagnostics.exportWithPanel(controller: controller) }
    @objc private func openSettings() { showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
