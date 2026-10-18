import AppKit
import Foundation

enum Paths {
    static let support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LiveSky", isDirectory: true)
    static var wallpapers: URL { support.appendingPathComponent("Wallpapers", isDirectory: true) }
    static var renders: URL { support.appendingPathComponent("Renders", isDirectory: true) }
    static var logs: URL { support.appendingPathComponent("Logs", isDirectory: true) }
    static var logFile: URL { logs.appendingPathComponent("LiveSky.log") }
    static var settings: URL { support.appendingPathComponent("settings.json") }
    static var state: URL { support.appendingPathComponent("state.json") }
    static var backups: URL { support.appendingPathComponent("original-wallpapers.json") }
    static var helpers: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true) }
    static var renderer: URL {
        helpers.appendingPathComponent("LiveSkyRenderer.app/Contents/MacOS/LiveSkyRenderer")
    }

    static func prepare() {
        for directory in [support, wallpapers, renders, logs] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    static func isLiveSkyWallpaper(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.standardizedFileURL.path.hasPrefix(wallpapers.standardizedFileURL.path + "/")
    }
}

enum Log {
    private static let queue = DispatchQueue(label: "LiveSky.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        let date = Date()
        queue.async {
            let line = "\(formatter.string(from: date)) \(level) \(message)\n"
            fputs(line, stderr)
            let url = Paths.logFile
            let manager = FileManager.default
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
                let previous = Paths.logs.appendingPathComponent("LiveSky.previous.log")
                try? manager.removeItem(at: previous)
                try? manager.moveItem(at: url, to: previous)
            }
            if !manager.fileExists(atPath: url.path) {
                try? manager.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
                manager.createFile(atPath: url.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            }
        }
    }

    static func recentLines(_ count: Int) -> String {
        queue.sync {
            guard let text = try? String(contentsOf: Paths.logFile, encoding: .utf8) else { return "" }
            return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(count).joined(separator: "\n")
        }
    }
}

enum JSONStore {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            Log.error("could not read \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            Log.error("could not write \(url.lastPathComponent): \(error)")
        }
    }
}

enum SystemInfo {
    /// Builds on which the WeatherUI bridge has been checked end to end.
    static let verifiedBuilds: Set<String> = ["24G720"]

    static var osBuild: String { sysctlString("kern.osversion") ?? "unknown" }
    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
    static var model: String { sysctlString("hw.model") ?? "unknown" }
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }
    static var isVerified: Bool { isAppleSilicon && verifiedBuilds.contains(osBuild) }
    static var versionDescription: String { "macOS \(osVersion) (\(osBuild))" }
    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Localized string from the app bundle (English and Simplified Chinese).
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), locale: Locale.current, arguments: arguments)
}

final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
