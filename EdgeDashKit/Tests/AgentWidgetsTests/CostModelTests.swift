import Foundation
import Testing
@testable import AgentWidgets

@Suite struct CostModelTests {
    @Test func pricingByTokenClass() {
        // fable: $5/M in, $25/M out; cache read 10%, cache write 125%.
        let counts = TokenCounts(input: 1_000_000, cacheRead: 10_000_000, cacheWrite: 1_000_000, output: 1_000_000)
        let cost = ModelPricing.cost(model: "claude-fable-5", counts: counts)
        // 5 + 10*0.5 + 1*6.25 + 25 = 41.25
        #expect(abs(cost - 41.25) < 0.001)
        #expect(ModelPricing.cost(model: "claude-haiku-4-5", counts: TokenCounts(output: 1_000_000)) == 5)
    }

    @Test func statsAggregateAcrossDaysAndModels() {
        let now = Date()
        let today = ClaudeSessionScanner.dayKey(now)
        let yesterday = ClaudeSessionScanner.dayKey(now.addingTimeInterval(-86400))
        let stats = UsageStats.build(
            byDayModel: [
                today: [
                    "claude-fable-5": TokenCounts(output: 1_000_000),      // $25
                    "claude-haiku-4-5": TokenCounts(output: 1_000_000),    // $5
                ],
                yesterday: ["claude-fable-5": TokenCounts(output: 2_000_000)], // $50
            ],
            now: now,
            dayKey: ClaudeSessionScanner.dayKey
        )
        #expect(abs(stats.costToday - 30) < 0.001)
        #expect(abs(stats.cost30d - 80) < 0.001)
        #expect(stats.tokensToday == 2_000_000)
        #expect(stats.tokens30d == 4_000_000)
        #expect(stats.topModel == "claude-fable-5")
        #expect(stats.dailyCosts.count == 30)
        #expect(abs(stats.dailyCosts[29] - 30) < 0.001) // newest = today
        #expect(abs(stats.dailyCosts[28] - 50) < 0.001)
    }

    @Test func depletionForecast() {
        let now = Date()
        // 10% burned in 30 min → 40% left → 2h to depletion.
        let samples: [(Date, Double)] = [(now.addingTimeInterval(-1800), 50), (now, 60)]
        let eta = ClaudeCodeMonitor.depletion(samples: samples)
        #expect(eta != nil)
        #expect(abs(eta! - 4 * 1800) < 1)
        // Flat usage → no forecast; single sample → no forecast.
        #expect(ClaudeCodeMonitor.depletion(samples: [(now.addingTimeInterval(-1800), 50), (now, 50.2)]) == nil)
        #expect(ClaudeCodeMonitor.depletion(samples: [(now, 50)]) == nil)
    }

    @Test func durationFormatting() {
        #expect(ClaudeCodeWidgetDuration(125 * 60) == "2h05m")
        #expect(ClaudeCodeWidgetDuration(48 * 60) == "48m")
        #expect(ClaudeCodeWidgetDuration((6 * 24 + 10) * 3600) == "6d10h")
    }
}

/// Internal indirection: the formatter lives on the (private-view-owning)
/// widget type.
private func ClaudeCodeWidgetDuration(_ seconds: TimeInterval) -> String {
    ClaudeCodeWidget.duration(seconds)
}
