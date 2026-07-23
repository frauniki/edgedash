import Foundation
import Testing
@testable import AgentWidgets

@Suite struct UsageLimitsTests {
    /// Shape captured live from api.anthropic.com/api/oauth/usage.
    private let fixture = """
    {
      "five_hour": {"utilization": 56.0, "resets_at": "2026-07-23T13:00:00.950436+00:00"},
      "seven_day": {"utilization": 14.0, "resets_at": "2026-07-29T21:00:00.950467+00:00"},
      "limits": [
        {"kind": "session", "group": "session", "percent": 56, "severity": "normal",
         "resets_at": "2026-07-23T13:00:00.950436+00:00", "scope": null, "is_active": true},
        {"kind": "weekly_all", "group": "weekly", "percent": 14, "severity": "normal",
         "resets_at": "2026-07-29T21:00:00.950467+00:00", "scope": null, "is_active": false},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 26, "severity": "normal",
         "resets_at": "2026-07-29T21:00:00.950839+00:00", "scope": {"model": "claude-fable-5"}, "is_active": false}
      ]
    }
    """

    @Test func parsesLimitsArray() throws {
        let limits = try #require(UsageLimits.parse(Data(fixture.utf8)))
        #expect(limits.windows.count == 3) // every reported window survives
        #expect(limits.session?.percent == 56)
        #expect(limits.session?.remaining == 44)
        #expect(limits.weeklyAll?.percent == 14)
        #expect(limits.weeklyScoped?.percent == 26)
        #expect(limits.weeklyScoped?.scope == "claude-fable-5")
        #expect(limits.weeklyScoped?.label == "7d·fable-5")
        let resets = try #require(limits.session?.resetsAt)
        // 2026-07-23T13:00:00Z regardless of the microsecond fraction.
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-07-23T13:00:00Z"))
        #expect(abs(resets.timeIntervalSince(expected)) < 1)
    }

    @Test func unknownWindowKindsAreKept() throws {
        let json = """
        {"limits": [
            {"kind": "session", "percent": 10},
            {"kind": "daily_routine", "percent": 0}
        ]}
        """
        let limits = try #require(UsageLimits.parse(Data(json.utf8)))
        #expect(limits.windows.count == 2)
        #expect(limits.windows[1].label == "daily routine")
        #expect(limits.windows[1].remaining == 100)
    }

    @Test func planNamePrettifies() {
        #expect(UsageLimits.planName(tier: "default_claude_max_5x", subscription: "max") == "Max 5x")
        #expect(UsageLimits.planName(tier: nil, subscription: "max") == "Max")
        #expect(UsageLimits.planName(tier: nil, subscription: nil) == nil)
    }

    @Test func fallsBackToSimpleWindows() throws {
        let json = #"{"five_hour": {"utilization": 30.0}, "seven_day": {"utilization": 5.0}}"#
        let limits = try #require(UsageLimits.parse(Data(json.utf8)))
        #expect(limits.session?.percent == 30)
        #expect(limits.weeklyAll?.percent == 5)
        #expect(UsageLimits.parse(Data("{}".utf8)) == nil)
    }

    @Test func microsecondTimestampParses() {
        #expect(UsageLimits.parseAPITimestamp("2026-07-23T13:00:00.950436+00:00") != nil)
        #expect(UsageLimits.parseAPITimestamp("2026-07-23T13:00:00Z") != nil)
        #expect(UsageLimits.parseAPITimestamp("garbage") == nil)
    }

    @Test func expiredTokenReturnsNil() {
        let now = Date()
        let live = """
        {"claudeAiOauth": {"accessToken": "tok-live", "rateLimitTier": "default_claude_max_5x",
         "expiresAt": \((now.timeIntervalSince1970 + 3600) * 1000)}}
        """
        let expired = """
        {"claudeAiOauth": {"accessToken": "tok-old", "expiresAt": \((now.timeIntervalSince1970 - 60) * 1000)}}
        """
        let liveCreds = ClaudeUsageFetcher.credentials(from: Data(live.utf8), now: now)
        #expect(liveCreds?.accessToken == "tok-live")
        #expect(liveCreds?.plan == "Max 5x")
        #expect(ClaudeUsageFetcher.credentials(from: Data(expired.utf8), now: now) == nil)
        // Flat (non-nested) credential shape also works.
        let flat = #"{"accessToken": "tok-flat"}"#
        #expect(ClaudeUsageFetcher.credentials(from: Data(flat.utf8), now: now)?.accessToken == "tok-flat")
    }
}
