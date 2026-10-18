import AppKit

struct Display {
    let screen: NSScreen
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
}

@MainActor
enum Displays {
    static func current() -> [Display] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            // Same UUID the system wallpaper store uses; stable across reconnects.
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
                ?? "display-\(id)"
            let scale = screen.backingScaleFactor
            return Display(screen: screen, id: id, uuid: uuid, name: screen.localizedName,
                           pixelWidth: Int((screen.frame.width * scale).rounded()),
                           pixelHeight: Int((screen.frame.height * scale).rounded()))
        }
    }

    static func signature(_ displays: [Display]) -> String {
        displays.map { "\($0.uuid):\($0.pixelWidth)x\($0.pixelHeight)" }.sorted().joined(separator: ",")
    }

    static var anyAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }
}

@MainActor
final class WallpaperManager {
    /// Exported but undocumented AppKit key. Without it only the current Space changes; with it
    /// AppKit walks every Space of the display without switching to them. Needs NSApplication.
    static let allSpacesKey = NSWorkspace.DesktopImageOptionKey(rawValue: "NSWorkspaceDesktopImageAllSpacesKey")

    private(set) var backups: [String: WallpaperBackup]

    init() {
        backups = JSONStore.load([String: WallpaperBackup].self, from: Paths.backups) ?? [:]
    }

    var hasBackups: Bool { !backups.isEmpty }

    /// Saves the display's current wallpaper before LiveSky changes it for the first time.
    func backUpIfNeeded(_ display: Display) {
        guard backups[display.uuid] == nil else { return }
        saveBackup(display)
    }

    /// On resume: if the user picked another wallpaper while LiveSky was paused, that becomes the
    /// wallpaper to restore later.
    func refreshBackupsAfterPause(_ displays: [Display]) {
        for display in displays {
            guard let existing = backups[display.uuid],
                  let current = NSWorkspace.shared.desktopImageURL(for: display.screen),
                  !Paths.isLiveSkyWallpaper(current), current.path != existing.path else { continue }
            saveBackup(display)
        }
    }

    private func saveBackup(_ display: Display) {
        guard let current = NSWorkspace.shared.desktopImageURL(for: display.screen),
              !Paths.isLiveSkyWallpaper(current) else { return }
        let options = NSWorkspace.shared.desktopImageOptions(for: display.screen) ?? [:]
        var backup = WallpaperBackup(displayName: display.name, path: current.path,
                                     imageScaling: (options[.imageScaling] as? NSNumber)?.intValue,
                                     allowClipping: (options[.allowClipping] as? NSNumber)?.boolValue,
                                     fillColor: nil, savedAt: Date())
        if let color = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB) {
            backup.fillColor = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map(Double.init)
        }
        backups[display.uuid] = backup
        JSONStore.save(backups, to: Paths.backups)
        Log.info("backed up the wallpaper of \(display.name): \(current.path)")
    }

    func set(_ url: URL, on display: Display) throws {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
            Self.allSpacesKey: true,
        ]
        try NSWorkspace.shared.setDesktopImageURL(url, for: display.screen, options: options)
    }

    struct RestoreResult {
        var restored: [String] = []
        var missing: [String] = []
        var failed: [String] = []
    }

    /// Puts each display's backed-up wallpaper back on all of its Spaces.
    func restore(_ displays: [Display]) -> RestoreResult {
        var result = RestoreResult()
        for display in displays {
            guard let backup = backups[display.uuid] else { continue }
            let url = URL(fileURLWithPath: backup.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                result.missing.append(display.name)
                Log.error("original wallpaper for \(display.name) is missing: \(backup.path)")
                continue
            }
            var options: [NSWorkspace.DesktopImageOptionKey: Any] = [Self.allSpacesKey: true]
            if let scaling = backup.imageScaling { options[.imageScaling] = scaling }
            if let clipping = backup.allowClipping { options[.allowClipping] = clipping }
            if let fill = backup.fillColor, fill.count == 4 {
                options[.fillColor] = NSColor(srgbRed: fill[0], green: fill[1], blue: fill[2], alpha: fill[3])
            }
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: display.screen, options: options)
                result.restored.append(display.name)
                Log.info("restored the original wallpaper of \(display.name)")
            } catch {
                result.failed.append(display.name)
                Log.error("could not restore \(display.name): \(error)")
            }
        }
        return result
    }

    /// Keeps the newest two wallpapers per display plus the ones in `keep` (the file in use).
    func prune(_ uuid: String, keep: Set<String>) {
        let prefix = "wallpaper-\(uuid)-"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: Paths.wallpapers.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".png") }
            .sorted()
        for name in names.dropLast(2) {
            let path = Paths.wallpapers.appendingPathComponent(name).path
            if !keep.contains(path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }
}
