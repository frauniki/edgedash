import Foundation
import Observation
import os

/// UI-facing state for the Claude Code widget: a periodically refreshed
/// snapshot of sessions and today's token totals. Runs only while a page
/// showing the widget is visible (same gating as metrics/music).
@MainActor @Observable public final class ClaudeCodeMonitor {
    public private(set) var sessions: [AgentSession] = []
    public private(set) var todayTotals = TokenTotals()
    /// Plan rate-limit windows (5h/weekly); nil until fetched or when the
    /// keychain/API is unavailable.
    public private(set) var usage: UsageLimits?
    /// Why `usage` is nil, for the widget's hint row.
    public private(set) var usageFailure: ClaudeUsageFetcher.Failure?

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
        case .failure(let failure):
            // Keep the last good value on transient failures; it beats flapping.
            usageFailure = failure
        }
    }

    /// Settings/widget retry: forget the backoff and fetch on the next tick.
    public func retryUsage() {
        lastUsageFetch = .distantPast
    }
}
