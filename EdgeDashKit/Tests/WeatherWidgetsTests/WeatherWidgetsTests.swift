import Foundation
import Testing
@testable import WeatherWidgets

private func fixtureData() throws -> Data {
    let url = try #require(Bundle.module.url(
        forResource: "forecast-tokyo", withExtension: "json", subdirectory: "Fixtures"
    ))
    return try Data(contentsOf: url)
}

/// Polls a MainActor condition — same helper style as MediaWidgetsTests.
@MainActor private func eventually(
    timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(condition(), "condition not met within \(timeout)s")
}

struct SnapshotBuildingTests {
    @Test func decodesRealResponseAndBuildsSnapshot() throws {
        let response = try JSONDecoder().decode(ForecastResponse.self, from: fixtureData())
        let snapshot = try #require(OpenMeteoClient.snapshot(from: response, fetchedAt: Date()))

        #expect(snapshot.current.temperature == 26.7)
        #expect(snapshot.current.isDay == false)
        #expect(snapshot.current.humidity == 81)
        #expect(snapshot.utcOffsetSeconds == 32400)

        // current.time is 23:30 — the slice starts at the 23:00 bucket and
        // crosses midnight.
        #expect(snapshot.hourly.count == 24)
        #expect(snapshot.hourly.first?.time == "2026-07-23T23:00")
        #expect(snapshot.hourly.first?.hourLabel == "23")
        #expect(snapshot.hourly.last?.time == "2026-07-24T22:00")

        #expect(snapshot.daily.count == 7)
        #expect(snapshot.daily.first?.date == "2026-07-23")
        #expect(snapshot.todayHigh == 36.3)
        #expect(snapshot.todayLow == 25.8)
    }

    @Test func toleratesNullsAndMissingArrays() throws {
        let json = """
        {
          "utc_offset_seconds": 0,
          "current": {"time": "2026-07-23T10:15", "temperature_2m": 20.0,
                      "relative_humidity_2m": 50, "apparent_temperature": 21.0,
                      "weather_code": 1, "wind_speed_10m": 2.0, "is_day": 1},
          "hourly": {"time": ["2026-07-23T10:00", "2026-07-23T11:00", "2026-07-23T12:00"],
                     "temperature_2m": [20.0, null, 22.0],
                     "weather_code": [1, null, null]},
          "daily": {"time": ["2026-07-23", "2026-07-24"],
                    "weather_code": [2, null],
                    "temperature_2m_max": [25.0, null],
                    "temperature_2m_min": [15.0, 14.0]}
        }
        """
        let response = try JSONDecoder().decode(ForecastResponse.self, from: Data(json.utf8))
        let snapshot = try #require(OpenMeteoClient.snapshot(from: response, fetchedAt: Date()))

        // Null temperature drops the hour; null code falls back to current's.
        #expect(snapshot.hourly.map(\.temperature) == [20.0, 22.0])
        #expect(snapshot.hourly.last?.code == 1)
        // Missing precipitation array reads as 0.
        #expect(snapshot.hourly.allSatisfy { $0.precipitationProbability == 0 })
        // A day without a full temperature range is dropped.
        #expect(snapshot.daily.count == 1)
        #expect(snapshot.daily.first?.high == 25.0)
    }

    @Test func sliceClampsWhenCurrentIsPastHourly() throws {
        let json = """
        {
          "utc_offset_seconds": 0,
          "current": {"time": "2026-07-25T10:15", "temperature_2m": 20.0,
                      "relative_humidity_2m": 50, "apparent_temperature": 21.0,
                      "weather_code": 1, "wind_speed_10m": 2.0, "is_day": 1},
          "hourly": {"time": ["2026-07-23T10:00", "2026-07-23T11:00"],
                     "temperature_2m": [20.0, 21.0],
                     "weather_code": [1, 1]},
          "daily": {"time": [], "weather_code": [],
                    "temperature_2m_max": [], "temperature_2m_min": []}
        }
        """
        let response = try JSONDecoder().decode(ForecastResponse.self, from: Data(json.utf8))
        let snapshot = try #require(OpenMeteoClient.snapshot(from: response, fetchedAt: Date()))
        // Degenerate but must not crash: slice starts at the last hour <= now.
        #expect(snapshot.hourly.count == 1)
    }

    @Test func helperFormatting() {
        #expect(OpenMeteoClient.hourLabel(from: "2026-07-23T09:00") == "09")
        #expect(OpenMeteoClient.weekdayLabel(
            isoDate: "2026-07-23", locale: Locale(identifier: "en_US_POSIX")
        ) == "Thu")
        #expect(WeatherUnits.display(0, fahrenheit: true) == 32)
        #expect(WeatherUnits.display(100, fahrenheit: true) == 212)
        #expect(WeatherUnits.degrees(26.7, fahrenheit: false) == "27°")
    }

    @Test func conditionMappingCoversWMOCodes() {
        // Every published WMO code maps to a specific symbol, day and night.
        let known = [
            0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67,
            71, 73, 75, 77, 80, 81, 82, 85, 86, 95, 96, 99,
        ]
        for code in known {
            #expect(WeatherCondition.text(code: code) != "—", "code \(code) unmapped")
            #expect(!WeatherCondition.symbol(code: code, isDay: true).isEmpty)
            #expect(!WeatherCondition.symbol(code: code, isDay: false).isEmpty)
        }
        // Clear sky flips day/night; unknown codes degrade to a plain cloud.
        #expect(WeatherCondition.symbol(code: 0, isDay: true) == "sun.max.fill")
        #expect(WeatherCondition.symbol(code: 0, isDay: false) == "moon.stars.fill")
        #expect(WeatherCondition.symbol(code: 42, isDay: true) == "cloud.fill")
    }
}

struct WeatherMonitorTests {
    /// Fetch-call bookkeeping the MainActor-bound `eventually` can read
    /// without suspension.
    @MainActor private final class Probe {
        var calls = 0
        var shouldFail = false
    }

    private static func miniResponse() throws -> ForecastResponse {
        try JSONDecoder().decode(ForecastResponse.self, from: fixtureData())
    }

    @MainActor @Test func fetchesOnceWhileFreshAndInflight() async throws {
        let probe = Probe()
        let monitor = WeatherMonitor(staleness: 900, failureCooldown: 0) { _, _ in
            await MainActor.run { probe.calls += 1 }
            return try Self.miniResponse()
        }
        let spec = WeatherMonitor.LocationSpec(latitude: 35.68, longitude: 139.76, label: "Tokyo")

        monitor.ensureFresh(spec)
        monitor.ensureFresh(spec) // in-flight: coalesced
        try await eventually { monitor.snapshots[spec.key] != nil }
        monitor.ensureFresh(spec) // fresh: skipped
        try await Task.sleep(for: .milliseconds(50))
        #expect(probe.calls == 1)
    }

    @MainActor @Test func staleSnapshotRefetches() async throws {
        let probe = Probe()
        let monitor = WeatherMonitor(staleness: 0, failureCooldown: 0) { _, _ in
            await MainActor.run { probe.calls += 1 }
            return try Self.miniResponse()
        }
        let spec = WeatherMonitor.LocationSpec(latitude: 35.68, longitude: 139.76, label: "Tokyo")

        monitor.ensureFresh(spec)
        try await eventually { monitor.snapshots[spec.key] != nil }
        monitor.ensureFresh(spec)
        try await eventually { probe.calls >= 2 }
        #expect(monitor.failures[spec.key] == nil)
    }

    @MainActor @Test func failureKeepsLastSnapshotAndCoolsDown() async throws {
        let probe = Probe()
        let monitor = WeatherMonitor(staleness: 0, failureCooldown: 3600) { _, _ in
            let failing = await MainActor.run {
                probe.calls += 1
                return probe.shouldFail
            }
            if failing { throw URLError(.notConnectedToInternet) }
            return try Self.miniResponse()
        }
        let spec = WeatherMonitor.LocationSpec(latitude: 35.68, longitude: 139.76, label: "Tokyo")

        monitor.ensureFresh(spec, now: Date(timeIntervalSinceNow: -7200))
        try await eventually { monitor.snapshots[spec.key] != nil }

        probe.shouldFail = true
        monitor.ensureFresh(spec) // staleness 0 → attempts, fails
        try await eventually { monitor.failures[spec.key] != nil }
        #expect(monitor.snapshots[spec.key] != nil) // stale beats blank

        monitor.ensureFresh(spec) // within cooldown → no third attempt
        try await Task.sleep(for: .milliseconds(50))
        #expect(probe.calls == 2)
    }
}

struct WeatherConfigTests {
    @Test func lenientDecoding() throws {
        let empty = try JSONDecoder().decode(WeatherWidget.Config.self, from: Data("{}".utf8))
        #expect(empty.mode == .auto)
        #expect(empty.place == nil)
        #expect(empty.fahrenheit == false)

        let garbageMode = try JSONDecoder().decode(
            WeatherWidget.Config.self,
            from: Data(#"{"mode": "teleport", "fahrenheit": true}"#.utf8)
        )
        #expect(garbageMode.mode == .auto)
        #expect(garbageMode.fahrenheit == true)
    }

    @Test func roundTrip() throws {
        var config = WeatherWidget.Config()
        config.mode = .manual
        config.place = .init(name: "東京都", latitude: 35.6895, longitude: 139.6917)
        config.fahrenheit = true
        let decoded = try JSONDecoder().decode(
            WeatherWidget.Config.self, from: JSONEncoder().encode(config)
        )
        #expect(decoded.mode == .manual)
        #expect(decoded.place?.name == "東京都")
        #expect(decoded.fahrenheit == true)
    }
}
