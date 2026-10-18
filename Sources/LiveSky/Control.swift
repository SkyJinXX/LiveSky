import AppKit

/// Debug control: `LiveSky.app/Contents/MacOS/LiveSky --ctl <command> [arguments]` talks to the
/// running instance through a local distributed notification, so updates and settings can be
/// driven without clicking. Run `--ctl help` for the list of commands.
enum ControlChannel {
    static let request = Notification.Name("local.livesky.LiveSky.control")
    static let reply = Notification.Name("local.livesky.LiveSky.control.reply")

    static let usage = """
    usage: LiveSky --ctl <command>
      status                      print the menu status and state as JSON
      update | retry              run an update and wait for it to finish
      pause | resume | restore    same as the menu items
      settings | close-settings   show or close the settings window
      menu [seconds]              open the status menu, closing it after the given seconds
      set-city <name>             choose the first Open-Meteo match as the manual city
      set-mode system|manual      choose the location mode
      complete-setup              finish first-run setup with the current choices
      set-interval <minutes>      5, 10, 15, 30 or 60
      login-item on|off           launch at login
      live [on|off]               print the live sky's state, or switch it on or off
      live-cap power|battery <c>  frame-rate ceiling: still, 12, 24, 30 or 60
      debug <option> <value>      simulate-incompatible|simulate-crash|simulate-offline|pretend-unverified on|off,
                                  interval-seconds <n>|off
      clear-failure               forget the recorded renderer failure
      simulate-screen-change      act as if the display layout changed (re-composes the last render)
      export-diagnostics <path>   write the diagnostics report to a file
      windows                     print LiveSky's on-screen window numbers
      quit
    """
}

enum ControlClient {
    static func run(_ arguments: [String]) -> Int32 {
        guard let command = arguments.first, command != "help" else {
            print(ControlChannel.usage)
            return arguments.isEmpty ? 2 : 0
        }
        let id = UUID().uuidString
        let center = DistributedNotificationCenter.default()
        let response = Box<String?>(nil)
        let observer = center.addObserver(forName: ControlChannel.reply, object: id, queue: nil) { note in
            response.value = note.userInfo?["message"] as? String ?? ""
        }
        center.postNotificationName(ControlChannel.request, object: id, userInfo: ["arguments": arguments],
                                    deliverImmediately: true)
        let limit: TimeInterval = ["update", "retry"].contains(command) ? 200 : 20
        let deadline = Date().addingTimeInterval(limit)
        while response.value == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        center.removeObserver(observer)
        guard let message = response.value else {
            fputs("no reply from LiveSky (is it running?)\n", stderr)
            return 1
        }
        print(message)
        return message.hasPrefix("error:") ? 1 : 0
    }
}

@MainActor
final class ControlServer: NSObject {
    private let controller: LiveSkyController
    private let settingsWindow: SettingsWindowController
    private let statusMenu: StatusMenuController

    init(controller: LiveSkyController, settingsWindow: SettingsWindowController, statusMenu: StatusMenuController) {
        self.controller = controller
        self.settingsWindow = settingsWindow
        self.statusMenu = statusMenu
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(received(_:)),
                                                            name: ControlChannel.request, object: nil,
                                                            suspensionBehavior: .deliverImmediately)
    }

    @objc private func received(_ note: Notification) {
        guard let id = note.object as? String, let arguments = note.userInfo?["arguments"] as? [String] else { return }
        Task { @MainActor in
            let message = await self.handle(arguments)
            DistributedNotificationCenter.default().postNotificationName(ControlChannel.reply, object: id,
                                                                         userInfo: ["message": message],
                                                                         deliverImmediately: true)
        }
    }

    /// Waits for the update attempt numbered `since + 1` to finish. A request made while an update
    /// is already running is covered by that update, so the same target applies.
    private func waitForUpdate(since: Int) async {
        let deadline = Date().addingTimeInterval(150)
        while controller.completedUpdates <= since, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func handle(_ arguments: [String]) async -> String {
        let command = arguments.first ?? ""
        let rest = Array(arguments.dropFirst())
        Log.info("control: \(arguments.joined(separator: " "))")
        switch command {
        case "status":
            return statusJSON()
        case "update", "retry":
            guard controller.settings.setupComplete else { return "error: setup is not complete" }
            guard !controller.settings.paused else { return "error: updates are paused" }
            let since = controller.completedUpdates
            command == "update" ? controller.updateNow() : controller.retry()
            await waitForUpdate(since: since)
            return statusJSON()
        case "pause":
            controller.pause()
            return statusJSON()
        case "resume":
            let since = controller.completedUpdates
            controller.resume()
            await waitForUpdate(since: since)
            return statusJSON()
        case "restore":
            controller.restoreOriginalWallpaper()
            return statusJSON()
        case "settings":
            settingsWindow.show()
            return "ok"
        case "close-settings":
            settingsWindow.close()
            return "ok"
        case "menu":
            let seconds = rest.first.flatMap(Double.init) ?? 5
            DispatchQueue.main.async { self.statusMenu.open(closeAfter: seconds) }
            return "ok: menu opens for \(seconds) s"
        case "set-city":
            let query = rest.joined(separator: " ")
            do {
                guard let place = try await OpenMeteo().searchCities(query, language: OpenMeteo.searchLanguage).first else {
                    return "error: no city matches \(query)"
                }
                controller.setManualPlace(place)
                return "ok: \(place.displayName) (\(place.timeZone))"
            } catch {
                return "error: \(error.localizedDescription)"
            }
        case "set-mode":
            guard let mode = rest.first.flatMap(LocationMode.init(rawValue:)) else { return "error: system or manual" }
            if mode == .manual, controller.settings.manualPlace == nil { return "error: choose a city first" }
            controller.setLocationMode(mode)
            return "ok"
        case "complete-setup":
            guard let mode = controller.settings.locationMode else { return "error: choose a location mode first" }
            let since = controller.completedUpdates
            controller.completeSetup(mode: mode, place: controller.settings.manualPlace,
                                     intervalMinutes: controller.settings.intervalMinutes,
                                     launchAtLogin: controller.settings.launchAtLogin)
            settingsWindow.close()
            await waitForUpdate(since: since)
            return statusJSON()
        case "set-interval":
            guard let minutes = rest.first.flatMap(Int.init), Settings.intervals.contains(minutes) else {
                return "error: 5, 10, 15, 30 or 60"
            }
            controller.setInterval(minutes)
            return "ok"
        case "live":
            if let value = rest.first {
                guard value == "on" || value == "off" else { return "error: live [on|off]" }
                controller.setLiveEnabled(value == "on")
            }
            return json(controller.live.debugInfo)
        case "live-cap":
            let caps: [String: LiveCap] = ["still": .still, "12": .fps12, "24": .fps24, "30": .fps30, "60": .fps60]
            guard rest.count == 2, rest[0] == "power" || rest[0] == "battery", let cap = caps[rest[1]] else {
                return "error: live-cap power|battery still|12|24|30|60"
            }
            controller.setLiveCap(cap, onBattery: rest[0] == "battery")
            return json(controller.live.debugInfo)
        case "login-item":
            controller.setLaunchAtLogin(rest.first == "on")
            return "ok: \(LoginItem.status) \(controller.loginItemNote ?? "")"
        case "debug":
            guard rest.count == 2 else { return "error: debug <option> <value>" }
            let on = rest[1] == "on"
            switch rest[0] {
            case "simulate-incompatible": controller.setDebug { $0.simulateIncompatible = on }
            case "simulate-crash": controller.setDebug { $0.simulateCrash = on }
            case "simulate-offline": controller.setDebug { $0.simulateOffline = on }
            case "pretend-unverified": controller.setDebug { $0.pretendUnverified = on }
            case "interval-seconds": controller.setDebug { $0.intervalSeconds = Int(rest[1]) }
            default: return "error: unknown option \(rest[0])"
            }
            return "ok"
        case "simulate-screen-change":
            let since = controller.completedUpdates
            controller.simulateScreenChange()
            await waitForUpdate(since: since)
            return statusJSON()
        case "clear-failure":
            controller.clearFailureForTesting()
            return statusJSON()
        case "export-diagnostics":
            guard let path = rest.first else { return "error: path required" }
            do {
                try Diagnostics.report(controller: controller).write(toFile: path, atomically: true, encoding: .utf8)
                return "ok: \(path)"
            } catch {
                return "error: \(error.localizedDescription)"
            }
        case "windows":
            let numbers = NSApp.windows.filter { $0.isVisible }.map { "\($0.windowNumber) \($0.className) \($0.title)" }
            return numbers.joined(separator: "\n")
        case "quit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            return "ok"
        default:
            return "error: unknown command \(command)\n" + ControlChannel.usage
        }
    }

    private func statusJSON() -> String {
        let iso = ISO8601DateFormatter()
        let state = controller.state
        let settings = controller.settings
        var info: [String: Any] = [
            "status": controller.statusLines,
            "menu": statusMenu.itemTitles,
            "updating": controller.isUpdating,
            "paused": settings.paused,
            "restored": state.restored,
            "setupComplete": settings.setupComplete,
            "locationMode": settings.locationMode?.rawValue ?? "",
            "intervalMinutes": settings.intervalMinutes,
            "applied": state.applied,
            "osBuild": SystemInfo.osBuild,
            "verified": controller.isVerifiedBuild,
            "loginItem": "\(LoginItem.status)",
        ]
        if let next = controller.nextUpdate { info["nextUpdate"] = iso.string(from: next) }
        if let last = state.lastSuccess { info["lastSuccess"] = iso.string(from: last) }
        if let error = controller.transientError { info["error"] = error }
        if let notice = controller.notice { info["notice"] = notice }
        if let weather = state.lastWeather {
            info["weather"] = ["place": weather.placeName, "condition": weather.condition, "code": weather.weatherCode,
                               "cloudCover": weather.cloudCover, "timeZone": weather.timeZone]
        }
        if let failure = state.failure {
            info["failure"] = ["kind": failure.kind, "check": failure.check, "detail": failure.detail,
                               "stage": failure.stage, "build": failure.osBuild, "exit": failure.exitDescription]
        }
        if let debug = try? JSONSerialization.jsonObject(with: JSONStore.encoder.encode(settings.debug)) {
            info["debug"] = debug
        }
        info["live"] = controller.live.debugInfo
        return json(info)
    }

    private func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
