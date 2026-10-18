import Foundation

/// Weather and city search through Open-Meteo (https://open-meteo.com). No API key needed.
struct OpenMeteo {
    var simulateOffline = false

    private var forecastBase: String {
        simulateOffline ? "http://127.0.0.1:9/v1/forecast" : "https://api.open-meteo.com/v1/forecast"
    }
    private var geocodingBase: String {
        simulateOffline ? "http://127.0.0.1:9/v1/search" : "https://geocoding-api.open-meteo.com/v1/search"
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "LiveSky/1.0 (macOS weather wallpaper)"]
        return URLSession(configuration: configuration)
    }()

    private func get<T: Decodable>(_ base: String, _ query: [URLQueryItem], as type: T.Type) async throws -> T {
        var components = URLComponents(string: base)!
        components.queryItems = query
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(from: components.url!)
        } catch {
            throw LiveSkyError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw LiveSkyError.network("HTTP \(http.statusCode)")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LiveSkyError.weather(L("error.weather.format"))
        }
    }

    // MARK: Forecast

    private struct ForecastResponse: Decodable {
        struct Current: Decodable {
            let time: Double
            let weather_code: Int
            let cloud_cover: Double
            let wind_speed_10m: Double
            let temperature_2m: Double?
        }
        struct Daily: Decodable {
            let time: [Double]
            let sunrise: [Double?]
            let sunset: [Double?]
        }
        let timezone: String
        let current: Current
        let daily: Daily
    }

    /// Current conditions plus today's sunrise and sunset in the place's own time zone.
    func weather(latitude: Double, longitude: Double, timeZone: String?, placeName: String) async throws -> WeatherSnapshot {
        let query = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "current", value: "weather_code,cloud_cover,wind_speed_10m,temperature_2m"),
            URLQueryItem(name: "daily", value: "sunrise,sunset"),
            URLQueryItem(name: "timezone", value: timeZone ?? "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
            URLQueryItem(name: "forecast_days", value: "2"),
        ]
        let result = try await get(forecastBase, query, as: ForecastResponse.self)
        let observed = Date(timeIntervalSince1970: result.current.time)
        guard abs(observed.timeIntervalSinceNow) <= 3600 else {
            throw LiveSkyError.weather(L("error.weather.stale"))
        }
        guard let condition = Self.condition(forCode: result.current.weather_code) else {
            throw LiveSkyError.weather(L("error.weather.code", result.current.weather_code))
        }
        guard let zone = TimeZone(identifier: result.timezone) else {
            throw LiveSkyError.weather(L("error.weather.format"))
        }
        // Daily arrays are ordered by local calendar day; compare in the place's time zone.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.dateComponents([.year, .month, .day], from: observed)
        var sunrise: Date?
        var sunset: Date?
        for (index, timestamp) in result.daily.time.enumerated() {
            let day = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: timestamp))
            if day == today {
                if index < result.daily.sunrise.count, let value = result.daily.sunrise[index] {
                    sunrise = Date(timeIntervalSince1970: value)
                }
                if index < result.daily.sunset.count, let value = result.daily.sunset[index] {
                    sunset = Date(timeIntervalSince1970: value)
                }
                break
            }
        }
        // Polar day or night: Open-Meteo has no real sunrise or sunset, so let WeatherUI decide.
        if let rise = sunrise, let set = sunset, set <= rise {
            sunrise = nil
            sunset = nil
        }
        return WeatherSnapshot(placeName: placeName, latitude: latitude, longitude: longitude, timeZone: result.timezone,
                               weatherCode: result.current.weather_code, condition: condition,
                               temperatureCelsius: result.current.temperature_2m,
                               cloudCover: min(1, max(0, result.current.cloud_cover / 100)),
                               windSpeed: max(0, result.current.wind_speed_10m),
                               observed: observed, sunrise: sunrise, sunset: sunset)
    }

    /// WMO weather code to WeatherKit condition, the same mapping as the research updater.
    static func condition(forCode code: Int) -> String? {
        switch code {
        case 0: return "clear"
        case 1: return "mostlyClear"
        case 2: return "partlyCloudy"
        case 3: return "cloudy"
        case 45, 48: return "foggy"
        case 51, 53, 55: return "drizzle"
        case 56, 57: return "freezingDrizzle"
        case 61, 63, 80, 81: return "rain"
        case 65, 82: return "heavyRain"
        case 66, 67: return "freezingRain"
        case 71, 73, 85: return "snow"
        case 75, 77, 86: return "heavySnow"
        case 95: return "thunderstorms"
        case 96, 99: return "strongStorms"
        default: return nil
        }
    }

    // MARK: Geocoding

    private struct SearchResponse: Decodable {
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let timezone: String?
            let admin1: String?
            let country: String?
        }
        let results: [Result]?
    }

    func searchCities(_ text: String, language: String) async throws -> [Place] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let query = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "count", value: "10"),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "format", value: "json"),
        ]
        let response = try await get(geocodingBase, query, as: SearchResponse.self)
        return (response.results ?? []).compactMap { result in
            guard let zone = result.timezone, TimeZone(identifier: zone) != nil else { return nil }
            return Place(name: result.name, admin1: result.admin1, country: result.country,
                         latitude: result.latitude, longitude: result.longitude, timeZone: zone)
        }
    }

    static var searchLanguage: String {
        (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("zh") ? "zh" : "en"
    }
}
