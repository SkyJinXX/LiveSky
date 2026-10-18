import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: LiveSkyController!
    private var statusMenu: StatusMenuController!
    private var settingsWindow: SettingsWindowController!
    private var control: ControlServer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let identifier = Bundle.main.bundleIdentifier ?? "local.livesky.LiveSky"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            // Already running (for example started by the login item): show its settings instead.
            DistributedNotificationCenter.default().postNotificationName(ControlChannel.request, object: UUID().uuidString,
                                                                         userInfo: ["arguments": ["settings"]],
                                                                         deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        if AppLocation.isTranslocated {
            let alert = NSAlert()
            alert.messageText = L("alert.translocated.title")
            alert.informativeText = L("alert.translocated.body")
            alert.addButton(withTitle: L("alert.quit"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        Paths.prepare()
        AppLocation.clearHelperQuarantine()
        controller = LiveSkyController()
        settingsWindow = SettingsWindowController(controller: controller)
        statusMenu = StatusMenuController(controller: controller) { [weak self] in self?.settingsWindow.show() }
        control = ControlServer(controller: controller, settingsWindow: settingsWindow, statusMenu: statusMenu)
        controller.start()
        if !controller.settings.setupComplete {
            settingsWindow.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow?.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
        Log.info("quit; the current wallpaper stays")
    }
}

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--ctl") {
    exit(ControlClient.run(Array(arguments[(index + 1)...])))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
