import Foundation

enum LocationMode: String, Codable {
    case system
    case manual
}

struct Place: Codable, Equatable, Hashable {
    var name: String
    var admin1: String?
    var country: String?
    var latitude: Double
    var longitude: Double
    var timeZone: String

    var displayName: String {
        var parts: [String] = [name]
        for part in [admin1, country].compactMap({ $0 }) where !part.isEmpty && !parts.contains(part) {
            parts.append(part)
        }
        return parts.joined(separator: ", ")
    }
}

struct DebugOptions: Codable, Equatable {
    var simulateIncompatible = false
    var simulateCrash = false
    var simulateOffline = false
    var pretendUnverified = false
    var intervalSeconds: Int?

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        simulateIncompatible = try c.decodeIfPresent(Bool.self, forKey: .simulateIncompatible) ?? false
        simulateCrash = try c.decodeIfPresent(Bool.self, forKey: .simulateCrash) ?? false
        simulateOffline = try c.decodeIfPresent(Bool.self, forKey: .simulateOffline) ?? false
        pretendUnverified = try c.decodeIfPresent(Bool.self, forKey: .pretendUnverified) ?? false
        intervalSeconds = try c.decodeIfPresent(Int.self, forKey: .intervalSeconds)
    }
}

/// Frame-rate ceilings for the live sky. WeatherUI picks its own rate for each kind of weather
/// (24 fps for clear skies, 30 for clouds and fog, 60 for rain, snow and storms); a ceiling only
/// ever lowers it. `still` leaves just the wallpaper.
enum LiveCap: Int, Codable, CaseIterable {
    case still = 0
    case fps12 = 12
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60
}

struct Settings: Codable, Equatable {
    static let intervals = [5, 10, 15, 30, 60]

    var setupComplete = false
    var locationMode: LocationMode?
    var manualPlace: Place?
    var intervalMinutes = 15
    var launchAtLogin = true
    /// Bundle path the login item was registered from; a moved app registers itself again.
    var loginItemPath: String?
    var paused = false
    /// The live sky: WeatherUI's animation behind the desktop icons, over the wallpaper.
    var liveEnabled = true
    var liveCapOnPower = LiveCap.fps60
    var liveCapOnBattery = LiveCap.fps12
    var debug = DebugOptions()

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        setupComplete = try c.decodeIfPresent(Bool.self, forKey: .setupComplete) ?? false
        locationMode = try c.decodeIfPresent(LocationMode.self, forKey: .locationMode)
        manualPlace = try c.decodeIfPresent(Place.self, forKey: .manualPlace)
        let interval = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 15
        intervalMinutes = Settings.intervals.contains(interval) ? interval : 15
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        loginItemPath = try c.decodeIfPresent(String.self, forKey: .loginItemPath)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        liveEnabled = try c.decodeIfPresent(Bool.self, forKey: .liveEnabled) ?? true
        liveCapOnPower = (try? c.decodeIfPresent(LiveCap.self, forKey: .liveCapOnPower)) ?? .fps60
        liveCapOnBattery = (try? c.decodeIfPresent(LiveCap.self, forKey: .liveCapOnBattery)) ?? .fps12
        debug = try c.decodeIfPresent(DebugOptions.self, forKey: .debug) ?? DebugOptions()
    }

    var updateInterval: TimeInterval {
        if let seconds = debug.intervalSeconds, seconds >= 10 { return TimeInterval(seconds) }
        return TimeInterval(intervalMinutes * 60)
    }
}

struct WeatherSnapshot: Codable, Equatable {
    var placeName: String
    var latitude: Double
    var longitude: Double
    var timeZone: String
    var weatherCode: Int
    var condition: String
    var temperatureCelsius: Double?
    var cloudCover: Double
    var windSpeed: Double
    var observed: Date
    var sunrise: Date?
    var sunset: Date?
}

/// A renderer or image-validation failure. These are treated as "this macOS version is not
/// compatible": the wallpaper is left untouched and automatic retries wait for a new OS build.
struct FailureRecord: Codable, Equatable {
    var kind: String
    var check: String
    var detail: String
    var stage: String
    var osVersion: String
    var osBuild: String
    var date: Date
    var exitDescription: String
    var stdout: String
    var stderr: String
}

struct AppState: Codable {
    var lastSuccess: Date?
    var lastSuccessBuild: String?
    var lastWeather: WeatherSnapshot?
    var lastSunElevation: Double?
    var lastSourcePath: String?
    var lastSourceDate: Date?
    var lastSourcePlace: String?
    /// Display UUID -> wallpaper file LiveSky last set on that display.
    var applied: [String: String] = [:]
    var appliedSignature: String?
    var failure: FailureRecord?
    var lastAttempt: Date?
    var lastAttemptBuild: String?
    /// Set by "Restore Original Wallpaper" until updates resume.
    var restored = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastSuccess = try c.decodeIfPresent(Date.self, forKey: .lastSuccess)
        lastSuccessBuild = try c.decodeIfPresent(String.self, forKey: .lastSuccessBuild)
        lastWeather = try? c.decodeIfPresent(WeatherSnapshot.self, forKey: .lastWeather)
        lastSunElevation = try c.decodeIfPresent(Double.self, forKey: .lastSunElevation)
        lastSourcePath = try c.decodeIfPresent(String.self, forKey: .lastSourcePath)
        lastSourceDate = try c.decodeIfPresent(Date.self, forKey: .lastSourceDate)
        lastSourcePlace = try c.decodeIfPresent(String.self, forKey: .lastSourcePlace)
        applied = try c.decodeIfPresent([String: String].self, forKey: .applied) ?? [:]
        appliedSignature = try c.decodeIfPresent(String.self, forKey: .appliedSignature)
        failure = try? c.decodeIfPresent(FailureRecord.self, forKey: .failure)
        lastAttempt = try c.decodeIfPresent(Date.self, forKey: .lastAttempt)
        lastAttemptBuild = try c.decodeIfPresent(String.self, forKey: .lastAttemptBuild)
        restored = try c.decodeIfPresent(Bool.self, forKey: .restored) ?? false
    }
}

struct WallpaperBackup: Codable, Equatable {
    var displayName: String
    var path: String
    var imageScaling: Int?
    var allowClipping: Bool?
    var fillColor: [Double]?
    var savedAt: Date
}

enum LiveSkyError: LocalizedError {
    case location(String)
    case network(String)
    case weather(String)
    case wallpaper(String)

    var errorDescription: String? {
        switch self {
        case .location(let message), .network(let message), .weather(let message), .wallpaper(let message):
            return message
        }
    }
}
