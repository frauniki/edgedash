import Foundation

/// One fetched forecast for one location, in display-ready form. Temperatures
/// are always Celsius — the °F toggle converts at render time so widgets with
/// different unit settings can share a cached snapshot.
public struct WeatherSnapshot: Sendable, Equatable {
    public struct Current: Sendable, Equatable {
        public var temperature: Double
        public var apparentTemperature: Double
        public var humidity: Double
        public var windSpeed: Double // m/s
        public var code: Int
        public var isDay: Bool
    }

    public struct Hour: Sendable, Equatable {
        /// Naive local ISO8601 in the *location's* timezone ("2026-07-23T20:00").
        public var time: String
        /// "20" — sliced from `time`, already location-local.
        public var hourLabel: String
        public var temperature: Double
        public var code: Int
        public var precipitationProbability: Double // 0–100
    }

    public struct Day: Sendable, Equatable {
        public var date: String // "2026-07-23"
        public var weekday: String // "Wed"
        public var code: Int
        public var high: Double
        public var low: Double
        public var precipitationProbability: Double // 0–100
    }

    public var current: Current
    /// Next 24 hours starting at the hour containing `current.time`.
    public var hourly: [Hour]
    /// Up to 7 days, first entry = today at the location.
    public var daily: [Day]
    public var fetchedAt: Date
    public var utcOffsetSeconds: Int

    /// Today's range for the compact layouts; falls back to the hourly span.
    public var todayHigh: Double? { daily.first?.high }
    public var todayLow: Double? { daily.first?.low }
}

/// WMO weather interpretation codes → SF Symbols + text.
/// https://open-meteo.com/en/docs — codes are a fixed WMO 4677 subset.
public enum WeatherCondition {
    public static func symbol(code: Int, isDay: Bool) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1: isDay ? "sun.min.fill" : "moon.stars.fill"
        case 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55: "cloud.drizzle.fill"
        case 56, 57, 66, 67: "cloud.sleet.fill"
        case 61, 63: "cloud.rain.fill"
        case 65: "cloud.heavyrain.fill"
        case 71, 73, 75, 77: "cloud.snow.fill"
        case 80, 81: isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 82: "cloud.heavyrain.fill"
        case 85, 86: "cloud.snow.fill"
        case 95: "cloud.bolt.fill"
        case 96, 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    public static func text(code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57: "Freezing drizzle"
        case 61, 63, 65: "Rain"
        case 66, 67: "Freezing rain"
        case 71, 73, 75, 77: "Snow"
        case 80, 81, 82: "Showers"
        case 85, 86: "Snow showers"
        case 95, 96, 99: "Thunderstorm"
        default: "—"
        }
    }
}

public enum WeatherUnits {
    public static func display(_ celsius: Double, fahrenheit: Bool) -> Double {
        fahrenheit ? celsius * 9 / 5 + 32 : celsius
    }

    /// "27°" — rounded, no unit suffix (the toggle is in settings).
    public static func degrees(_ celsius: Double, fahrenheit: Bool) -> String {
        String(format: "%.0f°", display(celsius, fahrenheit: fahrenheit))
    }
}
