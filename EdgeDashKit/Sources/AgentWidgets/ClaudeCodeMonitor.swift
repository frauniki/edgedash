import Foundation
import Observation
import os

/// UI-facing state for the Claude Code widget: a periodically refreshed
/// snapshot of sessions and today's token totals. Runs only while a page
/// showing the widget is visible (same gating as metrics/music).
@MainActor @Observable public final class ClaudeCodeMonitor {
    /// Seconds until each window hits 100% at the observed burn rate; nil
    /// while flat/cooling or with too little history.
    public struct Forecasts: Sendable, Equatable {
        public var session: TimeInterval?
        public var weeklyAll: TimeInterval?
        public var weeklyScoped: TimeInterval?
    }

    public private(set) var sessions: [AgentSession] = []
    public private(set) var todayTotals = TokenTotals()
    public private(set) var stats = UsageStats()
    /// Plan rate-limit windows (5h/weekly); nil until fetched or when the
    /// keychain/API is unavailable.
    public private(set) var usage: UsageLimits?
    public private(set) var forecasts = Forecasts()
    /// Why `usage` is nil, for the widget's hint row.
    public private(set) var usageFailure: ClaudeUsageFetcher.Failure?

    private var samples: [String: [(Date, Double)]] = [:]

    private let scanner: ClaudeSessionScanner
    private let usageFetcher = ClaudeUsageFetcher()
    private let interval: Duration
    private let usageInterval: TimeInterval = 300
    private var pollTask: Task<Void, Never>?
    private var lastUsageFetch = Date.distantPast

    public init(root: URL? = nil, interval: Duration = .seconds(5)) {
        scanner = ClaudeSessionScanner(root: root)
        self.interval = interval
    }

    private static let log = Logger(subsystem: "jp.sinoa.edgedash", category: "usage")

    public func setActive(_ active: Bool) {
        Self.log.info("monitor setActive \(active) (task running: \(self.pollTask != nil))")
        if active {
            guard pollTask == nil else { return }
            pollTask = Task { [scanner, interval] in
                while !Task.isCancelled {
                    let snapshot = await scanner.scan(now: Date())
                    guard !Task.isCancelled else { return }
                    sessions = snapshot.sessions
                    todayTotals = snapshot.todayTotals
                    stats = snapshot.stats
                    await refreshUsageIfStale()
                    try? await Task.sleep(for: interval)
                }
            }
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private func refreshUsageIfStale() async {
        guard Date().timeIntervalSince(lastUsageFetch) > usageInterval else { return }
        lastUsageFetch = Date()
        switch await usageFetcher.fetch() {
        case .limits(let fetched):
            usage = fetched
            usageFailure = nil
            recordSamples(fetched, now: Date())
        case .failure(let failure):
            // Keep the last good value on transient failures; it beats flapping.
            usageFailure = failure
        }
    }

    private func recordSamples(_ limits: UsageLimits, now: Date) {
        func record(_ kind: String, _ window: UsageLimits.Window?) -> TimeInterval? {
            guard let window else { return nil }
            var history = samples[kind] ?? []
            // A drop means the window reset — old slope is meaningless.
            if let last = history.last, window.percent < last.1 { history = [] }
            history.append((now, window.percent))
            history.removeAll { now.timeIntervalSince($0.0) > 3600 }
            samples[kind] = history
            return Self.depletion(samples: history)
        }
        forecasts = Forecasts(
            session: record("session", limits.session),
            weeklyAll: record("weekly_all", limits.weeklyAll),
            weeklyScoped: record("weekly_scoped", limits.weeklyScoped)
        )
    }

    /// Linear burn-rate projection over the retained samples.
    nonisolated static func depletion(samples: [(Date, Double)]) -> TimeInterval? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let elapsed = last.0.timeIntervalSince(first.0)
        let risen = last.1 - first.1
        guard elapsed > 60, risen > 0.5, last.1 < 100 else { return nil }
        return (100 - last.1) / (risen / elapsed)
    }

    /// Settings/widget retry: forget the backoff and fetch on the next tick.
    public func retryUsage() {
        lastUsageFetch = .distantPast
    }
}
