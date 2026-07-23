import Foundation
import Observation
import os

/// Shared weather cache, keyed by rounded coordinates. Unlike the media/agent
/// services there is no setActive gating: locations live in per-widget
/// configs the app layer can't see, so polling is view-driven — each visible
/// WeatherView's `.task` calls `ensureFresh` and the monitor collapses those
/// into at most one fetch per location per staleness window.
@MainActor @Observable public final class WeatherMonitor {
    public struct LocationSpec: Hashable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public var label: String

        public init(latitude: Double, longitude: Double, label: String) {
            self.latitude = latitude
            self.longitude = longitude
            self.label = label
        }

        /// ~1 km grid: widgets pointing at "the same place" share a snapshot.
        public var key: String {
            String(format: "%.2f,%.2f", latitude, longitude)
        }
    }

    public private(set) var snapshots: [String: WeatherSnapshot] = [:]
    /// Last fetch error per location; cleared by the next success. The last
    /// good snapshot is kept through failures — stale beats blank.
    public private(set) var failures: [String: String] = [:]
    public let location: LocationProvider

    private let staleness: TimeInterval
    private let failureCooldown: TimeInterval
    private let fetcher: @Sendable (Double, Double) async throws -> ForecastResponse
    private var inflight: Set<String> = []
    private var lastAttempt: [String: Date] = [:]

    private static let log = Logger(subsystem: "jp.sinoa.edgedash", category: "weather")

    public init(
        staleness: TimeInterval = 900,
        failureCooldown: TimeInterval = 60,
        location: LocationProvider? = nil,
        fetcher: @escaping @Sendable (Double, Double) async throws -> ForecastResponse = OpenMeteoClient.fetchForecast
    ) {
        self.staleness = staleness
        self.failureCooldown = failureCooldown
        self.location = location ?? LocationProvider()
        self.fetcher = fetcher
    }

    /// Fetches unless a fresh snapshot exists, a fetch is already running, or
    /// the last attempt failed within the cooldown (the view loop re-calls
    /// every minute — without the cooldown a dead network means a request
    /// per call).
    public func ensureFresh(_ spec: LocationSpec, now: Date = Date()) {
        let key = spec.key
        guard !inflight.contains(key) else { return }
        if let snapshot = snapshots[key], now.timeIntervalSince(snapshot.fetchedAt) < staleness { return }
        if let attempt = lastAttempt[key], now.timeIntervalSince(attempt) < failureCooldown { return }

        inflight.insert(key)
        lastAttempt[key] = now
        Task {
            defer { inflight.remove(key) }
            do {
                let response = try await fetcher(spec.latitude, spec.longitude)
                guard let snapshot = OpenMeteoClient.snapshot(from: response, fetchedAt: Date()) else {
                    failures[key] = "Empty forecast"
                    return
                }
                snapshots[key] = snapshot
                failures[key] = nil
            } catch {
                Self.log.warning("weather fetch failed for \(key): \(error.localizedDescription)")
                failures[key] = error.localizedDescription
            }
        }
    }
}
