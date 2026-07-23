import Foundation
import Observation

/// UI-facing state for the Claude Code widget: a periodically refreshed
/// snapshot of sessions and today's token totals. Runs only while a page
/// showing the widget is visible (same gating as metrics/music).
@MainActor @Observable public final class ClaudeCodeMonitor {
    public private(set) var sessions: [AgentSession] = []
    public private(set) var todayTotals = TokenTotals()

    private let scanner: ClaudeSessionScanner
    private let interval: Duration
    private var pollTask: Task<Void, Never>?

    public init(root: URL? = nil, interval: Duration = .seconds(5)) {
        scanner = ClaudeSessionScanner(root: root)
        self.interval = interval
    }

    public func setActive(_ active: Bool) {
        if active {
            guard pollTask == nil else { return }
            pollTask = Task { [scanner, interval] in
                while !Task.isCancelled {
                    let snapshot = await scanner.scan(now: Date())
                    guard !Task.isCancelled else { return }
                    sessions = snapshot.sessions
                    todayTotals = snapshot.todayTotals
                    try? await Task.sleep(for: interval)
                }
            }
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }
}
