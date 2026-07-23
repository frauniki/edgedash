// Open-Meteo (https://open-meteo.com) — free, key-less forecast + geocoding.
// Weather data by Open-Meteo.com, CC BY 4.0 (attribution in NOTICE).

import Foundation

/// Raw wire format. Numeric forecast arrays may contain nulls depending on
/// region/model, so every element is optional and the snapshot builder
/// drops/repairs gaps.
public struct ForecastResponse: Decodable, Sendable {
    public struct Current: Decodable, Sendable {
        var time: String
        var temperature_2m: Double
        var relative_humidity_2m: Double
        var apparent_temperature: Double
        var weather_code: Int
        var wind_speed_10m: Double
        var is_day: Int
    }

    public struct Hourly: Decodable, Sendable {
        var time: [String]
        var temperature_2m: [Double?]
        var weather_code: [Int?]
        var precipitation_probability: [Double?]?
    }

    public struct Daily: Decodable, Sendable {
        var time: [String]
        var weather_code: [Int?]
        var temperature_2m_max: [Double?]
        var temperature_2m_min: [Double?]
        var precipitation_probability_max: [Double?]?
    }

    var utc_offset_seconds: Int
    var current: Current
    var hourly: Hourly
    var daily: Daily
}

public struct GeocodedPlace: Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var admin1: String?
    public var country: String?
    public var latitude: Double
    public var longitude: Double

    /// "東京都 · 日本" style disambiguator under the name.
    public var detail: String {
        [admin1, country].compactMap(\.self).joined(separator: " · ")
    }
}

public enum OpenMeteoClient {
    public static func fetchForecast(latitude: Double, longitude: Double) async throws -> ForecastResponse {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "7"),
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? false else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ForecastResponse.self, from: data)
    }

    public static func geocode(_ query: String) async throws -> [GeocodedPlace] {
        struct Response: Decodable {
            struct Result: Decodable {
                var id: Int
                var name: String
                var admin1: String?
                var country: String?
                var latitude: Double
                var longitude: Double
            }
            var results: [Result]?
        }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: "5"),
            URLQueryItem(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? false else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data).results?.map {
            GeocodedPlace(
                id: $0.id, name: $0.name, admin1: $0.admin1, country: $0.country,
                latitude: $0.latitude, longitude: $0.longitude
            )
        } ?? []
    }

    // MARK: - Pure mapping (unit-tested)

    /// Wire → display snapshot. All time math uses the response's own local
    /// times — never the Mac's timezone (a Tokyo widget on a US Mac must not
    /// shift). Returns nil only when the response is unusably empty.
    public static func snapshot(from response: ForecastResponse, fetchedAt: Date) -> WeatherSnapshot? {
        let current = WeatherSnapshot.Current(
            temperature: response.current.temperature_2m,
            apparentTemperature: response.current.apparent_temperature,
            humidity: response.current.relative_humidity_2m,
            windSpeed: response.current.wind_speed_10m,
            code: response.current.weather_code,
            isDay: response.current.is_day == 1
        )

        // Slice 24 entries starting at the hour containing current.time.
        // Naive ISO8601 with fixed field widths compares lexicographically.
        let hourly = response.hourly
        let start = hourly.time.lastIndex { $0 <= response.current.time } ?? 0
        var hours: [WeatherSnapshot.Hour] = []
        for index in start..<min(start + 24, hourly.time.count) {
            // Null temperature makes the entry useless for the curve; drop it.
            guard let temperature = hourly.temperature_2m[safe: index] ?? nil else { continue }
            let time = hourly.time[index]
            let code = (hourly.weather_code[safe: index] ?? nil) ?? current.code
            let precip = hourly.precipitation_probability.flatMap { $0[safe: index] ?? nil } ?? 0
            hours.append(WeatherSnapshot.Hour(
                time: time,
                hourLabel: hourLabel(from: time),
                temperature: temperature,
                code: code,
                precipitationProbability: precip
            ))
        }

        var days: [WeatherSnapshot.Day] = []
        for index in response.daily.time.indices {
            guard let high = response.daily.temperature_2m_max[safe: index] ?? nil,
                  let low = response.daily.temperature_2m_min[safe: index] ?? nil else { continue }
            let code = (response.daily.weather_code[safe: index] ?? nil) ?? 3
            let precip = response.daily.precipitation_probability_max.flatMap { $0[safe: index] ?? nil } ?? 0
            days.append(WeatherSnapshot.Day(
                date: response.daily.time[index],
                weekday: weekdayLabel(isoDate: response.daily.time[index]),
                code: code,
                high: high,
                low: low,
                precipitationProbability: precip
            ))
        }

        guard !hours.isEmpty || !days.isEmpty else { return nil }
        return WeatherSnapshot(
            current: current,
            hourly: hours,
            daily: days,
            fetchedAt: fetchedAt,
            utcOffsetSeconds: response.utc_offset_seconds
        )
    }

    /// "2026-07-23T20:00" → "20".
    static func hourLabel(from naiveISO: String) -> String {
        guard let tIndex = naiveISO.firstIndex(of: "T") else { return naiveISO }
        return String(naiveISO[naiveISO.index(after: tIndex)...].prefix(2))
    }

    /// "2026-07-23" → localized short weekday ("Wed"). The date string is
    /// already location-local, so a GMT calendar reads it back unshifted.
    static func weekdayLabel(isoDate: String, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: isoDate) else { return "" }
        let output = DateFormatter()
        output.locale = locale
        output.timeZone = TimeZone(secondsFromGMT: 0)
        output.setLocalizedDateFormatFromTemplate("EEE")
        return output.string(from: date)
    }
}

extension Array {
    /// nil instead of a crash for the ragged/short arrays Open-Meteo can return.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
