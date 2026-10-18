import AppKit
import ServiceManagement
import UniformTypeIdentifiers

/// Launch at login through SMAppService, with a per-user LaunchAgent as the fallback when the
/// ad-hoc signature is not accepted.
@MainActor
enum LoginItem {
    static let agentLabel = "local.livesky.LiveSky"
    static var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    enum Status { case enabled, requiresApproval, launchAgent, disabled }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return FileManager.default.fileExists(atPath: agentPlist.path) ? .launchAgent : .disabled
        }
    }

    /// Returns a user-facing note when something needs attention, otherwise nil.
    @discardableResult
    static func apply(_ enabled: Bool) -> String? {
        let service = SMAppService.mainApp
        guard enabled else {
            if service.status == .enabled || service.status == .requiresApproval {
                do { try service.unregister() } catch { Log.error("login item unregister failed: \(error)") }
            }
            removeAgent()
            return nil
        }
        if service.status == .enabled {
            removeAgent()
            return nil
        }
        if service.status == .requiresApproval {
            return L("settings.loginItem.approval")
        }
        do {
            try service.register()
            removeAgent()
            Log.info("registered login item with SMAppService (status \(service.status.rawValue))")
            return service.status == .requiresApproval ? L("settings.loginItem.approval") : nil
        } catch {
            let code = (error as NSError).code
            Log.error("SMAppService register failed (\(code)): \(error.localizedDescription)")
            // Respect an explicit "no" from the user in System Settings.
            if code == kSMErrorLaunchDeniedByUser { return L("settings.loginItem.approval") }
            return installAgent()
        }
    }

    private static func installAgent() -> String? {
        guard let executable = Bundle.main.executablePath else { return L("settings.loginItem.failed") }
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        do {
            try FileManager.default.createDirectory(at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentPlist, options: .atomic)
            Log.info("installed LaunchAgent fallback at \(agentPlist.path)")
            return nil
        } catch {
            Log.error("LaunchAgent fallback failed: \(error)")
            return L("settings.loginItem.failed")
        }
    }

    private static func removeAgent() {
        if FileManager.default.fileExists(atPath: agentPlist.path) {
            try? FileManager.default.removeItem(at: agentPlist)
            Log.info("removed LaunchAgent fallback")
        }
    }
}

enum AppLocation {
    /// Gatekeeper runs a quarantined app that was not moved by the user from a random read-only
    /// path. Login items and helper launches are unreliable there.
    static var isTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    /// The user already approved LiveSky in Gatekeeper; drop the download quarantine from the
    /// embedded renderer so launching it never triggers a second Gatekeeper prompt.
    static func clearHelperQuarantine() {
        let root = Paths.helpers
        var cleared = 0
        func clear(_ url: URL) {
            if getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0,
               removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0 {
                cleared += 1
            }
        }
        clear(root)
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator { clear(url) }
        }
        if cleared > 0 { Log.info("cleared download quarantine from \(cleared) renderer files") }
    }
}

enum Diagnostics {
    @MainActor
    static func report(controller: LiveSkyController) -> String {
        let settings = controller.settings
        let state = controller.state
        let iso = ISO8601DateFormatter()
        var lines = [
            "LiveSky diagnostics",
            "Generated: \(iso.string(from: Date()))",
            "App: \(SystemInfo.appVersion) at \(Bundle.main.bundlePath)",
            "System: \(SystemInfo.versionDescription), \(SystemInfo.model), Apple silicon: \(SystemInfo.isAppleSilicon)",
            "Verified build: \(SystemInfo.isVerified ? "yes" : "no") (verified: \(SystemInfo.verifiedBuilds.sorted().joined(separator: ", ")))",
            "Language: \(Bundle.main.preferredLocalizations.first ?? "?")",
            "Location mode: \(settings.locationMode?.rawValue ?? "not chosen"), interval: \(settings.intervalMinutes) min, paused: \(settings.paused)",
            "Displays: \(Displays.signature(Displays.current()))",
            "Last success: \(state.lastSuccess.map { iso.string(from: $0) } ?? "never") on build \(state.lastSuccessBuild ?? "-")",
        ]
        if let weather = state.lastWeather {
            lines.append("Last weather: \(weather.condition) (code \(weather.weatherCode)), cloud \(Int(weather.cloudCover * 100))%, time zone \(weather.timeZone)")
        }
        if let error = controller.transientError {
            lines.append("Last error: \(error)")
        }
        if let failure = state.failure {
            lines += [
                "",
                "== Renderer failure ==",
                "When: \(iso.string(from: failure.date))",
                "System: macOS \(failure.osVersion) (\(failure.osBuild))",
                "Kind: \(failure.kind)",
                "Failing check: \(failure.check)",
                "Detail: \(failure.detail)",
                "Stage: \(failure.stage)",
                "Exit: \(failure.exitDescription)",
                "",
                "== Renderer stdout ==",
                failure.stdout,
                "",
                "== Renderer stderr ==",
                failure.stderr,
            ]
        } else {
            lines.append("Renderer failure: none")
        }
        lines += ["", "== Recent log ==", Log.recentLines(200)]
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func exportWithPanel(controller: LiveSkyController) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "LiveSky-diagnostics-\(formatter.string(from: Date())).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report(controller: controller).write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
