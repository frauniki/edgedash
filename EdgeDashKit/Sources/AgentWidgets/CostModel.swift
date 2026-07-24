import Foundation

/// Token classes priced differently by the API.
public struct TokenCounts: Sendable, Equatable {
    public var input = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var output = 0

    public init(input: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, output: Int = 0) {
        self.input = input
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.output = output
    }

    public var allInput: Int {
        input + cacheRead + cacheWrite
    }

    public var total: Int {
        allInput + output
    }

    public mutating func add(_ other: TokenCounts) {
        input += other.input
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
        output += other.output
    }
}

/// API list prices per MTok, CodexBar-style "estimated at API rates".
/// Cache reads bill at 10% of input, cache writes at 125%.
public enum ModelPricing {
    /// (input, output) $ per million tokens, matched by model-name substring.
    static func rates(for model: String) -> (input: Double, output: Double) {
        let lowered = model.lowercased()
        if lowered.contains("haiku") { return (1, 5) }
        if lowered.contains("sonnet") { return (3, 15) }
        if lowered.contains("opus") { return (5, 25) }
        if lowered.contains("fable") || lowered.contains("mythos") { return (5, 25) }
        return (5, 25)
    }

    public static func cost(model: String, counts: TokenCounts) -> Double {
        let rates = rates(for: model)
        let millions = { (tokens: Int) in Double(tokens) / 1_000_000 }
        return millions(counts.input) * rates.input
            + millions(counts.cacheRead) * rates.input * 0.1
            + millions(counts.cacheWrite) * rates.input * 1.25
            + millions(counts.output) * rates.output
    }

    public static func dollars(_ value: Double) -> String {
        value >= 100 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }
}

/// 30-day accounting derived from the local transcripts.
public struct UsageStats: Sendable, Equatable {
    public var costToday: Double = 0
    public var cost30d: Double = 0
    public var tokensToday: Int = 0
    public var tokens30d: Int = 0
    /// One entry per day, oldest → today (30 entries), estimated dollars.
    public var dailyCosts: [Double] = []
    public var topModel: String?
    /// Total tokens of the most recently active session.
    public var latestSessionTokens: Int = 0

    public init() {}

    static func build(
        byDayModel: [String: [String: TokenCounts]],
        now: Date,
        dayKey: (Date) -> String
    ) -> UsageStats {
        var stats = UsageStats()
        let today = dayKey(now)

        var costByDay: [String: Double] = [:]
        var costByModel: [String: Double] = [:]
        for (day, models) in byDayModel {
            for (model, counts) in models {
                let cost = ModelPricing.cost(model: model, counts: counts)
                costByDay[day, default: 0] += cost
                costByModel[model, default: 0] += cost
                stats.cost30d += cost
                stats.tokens30d += counts.total
                if day == today {
                    stats.costToday += cost
                    stats.tokensToday += counts.total
                }
            }
        }
        let calendar = Calendar.current
        stats.dailyCosts = (0..<30).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: now).map { costByDay[dayKey($0)] ?? 0 }
        }
        stats.topModel = costByModel.max { $0.value < $1.value }?.key
        return stats
    }
}
