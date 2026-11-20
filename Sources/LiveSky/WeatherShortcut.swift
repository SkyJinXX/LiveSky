import AppKit
import WeatherKit

/// The "LiveSky Weather" shortcut: Get Current Weather → Get Details (Condition) → Stop and
/// Output. Shortcuts reads Apple Weather, the Weather app's own source, which sees rain that
/// Open-Meteo's models miss. LiveSky takes only the condition from it, and only when "Match the
/// Weather app" is on.
enum WeatherShortcut {
    static let name = "LiveSky Weather"
    /// The shared copy, on iCloud.
    static let shareURL = URL(string: "https://www.icloud.com/shortcuts/55fec3f58d994b96aa309cacdb0950cb")!
    static let timeout: TimeInterval = 20

    struct Reading {
        /// WeatherKit condition raw value, as the renderer takes it.
        var condition: String
        /// What the shortcut printed.
        var label: String
    }

    struct Problem: Error {
        var reason: String
    }

    /// Runs the shortcut off the main thread and reads its condition.
    static func read(name: String = name) async -> Result<Reading, Problem> {
        await background { readNow(name) }
    }

    /// Whether Shortcuts has a shortcut with exactly this name.
    static func isInstalled(name: String = name) async -> Bool {
        await background {
            guard case .success(let output) = shortcuts(["list"]), output.succeeded else { return false }
            return output.stdout.split(separator: "\n").contains { $0 == name }
        }
    }

    /// Hands the shared copy straight to Shortcuts, which shows Add Shortcut. A browser left the iCloud
    /// page unanswered in testing, so the page itself is only the fallback.
    static func offerToAdd() {
        guard let shortcuts = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") else {
            NSWorkspace.shared.open(shareURL)
            return
        }
        NSWorkspace.shared.open([shareURL], withApplicationAt: shortcuts, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async { NSWorkspace.shared.open(shareURL) }
        }
    }

    /// Opens the shortcut in the Shortcuts editor, where running it once asks for location access.
    static func openInShortcuts() {
        var components = URLComponents(string: "shortcuts://open-shortcut")!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    /// Shortcuts prints WeatherKit's own condition names, in its own language. An exact name wins;
    /// otherwise the longest name the output starts with, which tolerates text typed after the
    /// variable.
    static func condition(forLabel label: String) -> String? {
        let text = squeezed(label)
        guard !text.isEmpty else { return nil }
        return names.first { $0.name == text }?.condition ?? names.first { text.hasPrefix($0.name) }?.condition
    }

    /// Open-Meteo's cloud cover, kept inside the sky-cover band of Apple's condition (the NWS
    /// eighths: clear up to 1/8, mostly clear to 3/8, partly cloudy to 5/8, mostly cloudy to 7/8),
    /// so the clouds drawn agree with the condition.
    static func cloudCover(_ cover: Double, for condition: String) -> Double {
        let bands: [String: ClosedRange<Double>] = [
            "clear": 0...0.125, "mostlyClear": 0.125...0.375, "partlyCloudy": 0.375...0.625,
            "mostlyCloudy": 0.625...0.875, "cloudy": 0.875...1,
        ]
        guard let band = bands[condition] else { return cover }
        return min(band.upperBound, max(band.lowerBound, cover))
    }

    /// WeatherKit's English names, which are also the keys of its translations. A clear sky has a
    /// daytime name as well: while the sun is up, Shortcuts says "Sunny" and "Mostly Sunny".
    private static let englishNames: [(condition: String, name: String)] = [
        ("blizzard", "Blizzard"), ("blowingDust", "Dust"), ("blowingSnow", "Blowing Snow"), ("breezy", "Breezy"),
        ("clear", "Clear"), ("clear", "Sunny"), ("cloudy", "Cloudy"), ("drizzle", "Drizzle"), ("flurries", "Flurries"),
        ("foggy", "Fog"), ("freezingDrizzle", "Freezing Drizzle"), ("freezingRain", "Freezing Rain"), ("frigid", "Cold"),
        ("hail", "Hail"), ("haze", "Haze"), ("heavyRain", "Heavy Rain"), ("heavySnow", "Heavy Snow"), ("hot", "Hot"),
        ("hurricane", "Hurricane"), ("isolatedThunderstorms", "Isolated Thunderstorms"),
        ("mostlyClear", "Mostly Clear"), ("mostlyClear", "Mostly Sunny"), ("mostlyCloudy", "Mostly Cloudy"),
        ("partlyCloudy", "Partly Cloudy"), ("rain", "Rain"), ("scatteredThunderstorms", "Scattered Thunderstorms"),
        ("sleet", "Sleet"), ("smoky", "Smoke"), ("snow", "Snow"), ("strongStorms", "Severe Thunderstorm"),
        ("sunFlurries", "Sun Flurries"), ("sunShowers", "Sun Showers"), ("thunderstorms", "Thunderstorm"),
        ("tropicalStorm", "Tropical Storm"), ("windy", "Windy"), ("wintryMix", "Wintry Mix"),
    ]

    /// Every condition's name in LiveSky's language and, from macOS 15.4, in each of WeatherKit's
    /// languages, so the output is understood whatever language Shortcuts runs in. A word can mean
    /// different conditions in different languages ("Granizo" is hail in one Spanish and sleet in
    /// another), so the first meaning seen wins: LiveSky's language, then the user's languages,
    /// which Shortcuts speaks, then English and the rest. Longest first, so a shorter name that
    /// begins a longer one never wins the prefix match.
    private static let names: [(name: String, condition: String)] = {
        var names: [(name: String, condition: String)] = WeatherCondition.allCases.map {
            (squeezed($0.description), $0.rawValue)
        }
        let english = englishNames.map { (name: squeezed($0.name), condition: $0.condition) }
        if #available(macOS 15.4, *), let bundle = Bundle(path: "/System/Library/Frameworks/WeatherKit.framework") {
            let preferred = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: Locale.preferredLanguages)
            func add(_ localizations: [String]) {
                for localization in localizations {
                    let language = [Locale.Language(identifier: localization)]
                    for (condition, key) in englishNames {
                        let name = bundle.localizedString(forKey: key, value: nil, table: nil, localizations: language)
                        names.append((squeezed(name), condition))
                    }
                }
            }
            add(preferred)
            names += english
            add(bundle.localizations.filter { !preferred.contains($0) })
        } else {
            names += english
        }
        var seen = Set<String>()
        return names.filter { !$0.name.isEmpty && seen.insert($0.name).inserted }.sorted { $0.name.count > $1.name.count }
    }()

    private static func squeezed(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    private static func readNow(_ name: String) -> Result<Reading, Problem> {
        let output: Output
        switch shortcuts(["run", name]) {
        case .failure(let problem): return .failure(problem)
        case .success(let result): output = result
        }
        guard output.succeeded else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(Problem(reason: message.isEmpty ? output.exit : String(message.prefix(200))))
        }
        let label = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            return .failure(Problem(reason: "no output; the shortcut has to end with Stop and Output"))
        }
        guard let condition = condition(forLabel: label) else {
            return .failure(Problem(reason: "unknown condition \"\(label.prefix(80))\""))
        }
        return .success(Reading(condition: condition, label: label))
    }

    private struct Output {
        var succeeded: Bool
        var exit: String
        var stdout: String
        var stderr: String
    }

    /// Runs /usr/bin/shortcuts with a time limit. Fails only when it can't start or runs too long.
    private static func shortcuts(_ arguments: [String]) -> Result<Output, Problem> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let outputData = Box(Data()), errorData = Box(Data())
        let readers = DispatchGroup()
        for (pipe, data) in [(output, outputData), (errors, errorData)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                data.value = pipe.fileHandleForReading.readDataToEndOfFile()
                readers.leave()
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            readers.wait()
            return .failure(Problem(reason: "could not start shortcuts: \(error.localizedDescription)"))
        }
        let timedOut = Box(false)
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.value = true
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        exited.wait()
        watchdog.cancel()
        readers.wait()

        if timedOut.value { return .failure(Problem(reason: "no answer after \(Int(timeout)) s")) }
        let exit = process.terminationReason == .uncaughtSignal
            ? "signal \(process.terminationStatus)" : "exit \(process.terminationStatus)"
        return .success(Output(succeeded: process.terminationReason == .exit && process.terminationStatus == 0, exit: exit,
                               stdout: String(decoding: outputData.value, as: UTF8.self),
                               stderr: String(decoding: errorData.value, as: UTF8.self)))
    }

    private static func background<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
        }
    }
}
