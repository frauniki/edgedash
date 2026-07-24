import Foundation
import os

/// Plan rate-limit windows as reported by Anthropic's OAuth usage endpoint —
/// the same numbers Claude Code's /usage shows (5-hour session window,
/// weekly, weekly per-model-group).
public struct UsageLimits: Sendable, Equatable {
    public struct Window: Sendable, Equatable, Identifiable {
        /// API kind ("session", "weekly_all", "weekly_scoped", …). Unknown
        /// future kinds are kept and displayed, not dropped.
        public var kind: String
        public var percent: Double // used, 0…100
        public var resetsAt: Date?
        public var severity: String?
        /// Scoped windows carry what they apply to (e.g. a model group).
        public var scope: String?

        public var id: String {
            kind + (scope ?? "")
        }

        public var remaining: Double {
            max(0, 100 - percent)
        }

        public init(kind: String, percent: Double, resetsAt: Date? = nil, severity: String? = nil, scope: String? = nil) {
            self.kind = kind
            self.percent = percent
            self.resetsAt = resetsAt
            self.severity = severity
            self.scope = scope
        }

        /// Short display label: "5h", "7d", "7d·fable-5", "daily routine"…
        public var label: String {
            switch kind {
            case "session": return "5h"
            case "weekly_all": return "7d"
            case "weekly_scoped":
                guard let scope else { return "7d·" }
                let trimmed = scope.hasPrefix("claude-") ? String(scope.dropFirst("claude-".count)) : scope
                return "7d·\(trimmed)"
            default:
                return kind.replacingOccurrences(of: "_", with: " ")
            }
        }
    }

    /// All windows the API reported, in its order.
    public var windows: [Window]
    /// "Max 5x" etc., from the local credentials' rate-limit tier.
    public var plan: String?

    public var session: Window? {
        windows.first { $0.kind == "session" }
    }

    public var weeklyAll: Window? {
        windows.first { $0.kind == "weekly_all" }
    }

    public var weeklyScoped: Window? {
        windows.first { $0.kind == "weekly_scoped" }
    }

    public init(windows: [Window] = [], plan: String? = nil) {
        self.windows = windows
        self.plan = plan
    }

    // MARK: - Parsing

    public static func parse(_ data: Data) -> UsageLimits? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var limits = UsageLimits()

        if let entries = object["limits"] as? [[String: Any]] {
            for entry in entries {
                guard let kind = entry["kind"] as? String else { continue }
                limits.windows.append(Window(
                    kind: kind,
                    percent: (entry["percent"] as? Double) ?? Double(entry["percent"] as? Int ?? 0),
                    resetsAt: (entry["resets_at"] as? String).flatMap(parseAPITimestamp),
                    severity: entry["severity"] as? String,
                    scope: scopeLabel(entry["scope"])
                ))
            }
        }

        // Fallback for older response shapes.
        if limits.session == nil, let window = simpleWindow(object["five_hour"], kind: "session") {
            limits.windows.insert(window, at: 0)
        }
        if limits.weeklyAll == nil, let window = simpleWindow(object["seven_day"], kind: "weekly_all") {
            limits.windows.append(window)
        }
        return limits.windows.isEmpty ? nil : limits
    }

    private static func simpleWindow(_ value: Any?, kind: String) -> Window? {
        guard let dict = value as? [String: Any],
              let utilization = dict["utilization"] as? Double else { return nil }
        return Window(
            kind: kind,
            percent: utilization,
            resetsAt: (dict["resets_at"] as? String).flatMap(parseAPITimestamp)
        )
    }

    private static func scopeLabel(_ value: Any?) -> String? {
        guard let dict = value as? [String: Any] else { return nil }
        return (dict["model"] as? String) ?? dict.values.compactMap { $0 as? String }.first
    }

    /// "default_claude_max_5x" → "Max 5x".
    static func planName(tier: String?, subscription: String?) -> String? {
        guard var name = tier ?? subscription else { return nil }
        for prefix in ["default_", "claude_"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        if name.hasPrefix("claude_") { name = String(name.dropFirst("claude_".count)) }
        let words = name.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// The endpoint uses microsecond fractions ("…13:00:00.950436+00:00")
    /// which ISO8601DateFormatter chokes on — strip the fraction; second
    /// precision is plenty for a reset countdown.
    static func parseAPITimestamp(_ text: String) -> Date? {
        var cleaned = text
        if let dot = cleaned.firstIndex(of: ".") {
            let tail = cleaned[dot...]
            if let end = tail.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
                cleaned.removeSubrange(dot..<end)
            }
        }
        return isoPlain.date(from: cleaned)
    }

    private nonisolated(unsafe) static let isoPlain = ISO8601DateFormatter()
}

/// Reads Claude Code's OAuth credentials from the login keychain and asks the
/// usage endpoint for the current windows. First access shows the system
/// keychain consent prompt once ("Always Allow" remembers the choice; TCC-
/// style, bound to the app's signature).
public actor ClaudeUsageFetcher {
    public enum Failure: Error, Sendable, Equatable {
        case keychainDenied
        case noCredentials
        case tokenExpired
        case requestFailed
    }

    public enum Outcome: Sendable, Equatable {
        case limits(UsageLimits)
        case failure(Failure)
    }

    private static let log = Logger(subsystem: "jp.sinoa.edgedash", category: "usage")

    public init() {}

    public func fetch() async -> Outcome {
        let credentials: Credentials
        switch Self.readCredentials() {
        case .success(let value): credentials = value
        case .failure(let failure): return .failure(failure)
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            Self.log.error("usage request failed (network)")
            return .failure(.requestFailed)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200, var limits = UsageLimits.parse(data) else {
            Self.log.error("usage request failed: HTTP \(status)")
            return .failure(status == 401 ? .tokenExpired : .requestFailed)
        }
        limits.plan = credentials.plan
        Self.log.info("usage fetched: session \(limits.session?.percent ?? -1, format: .fixed(precision: 0))%")
        return .limits(limits)
    }

    // MARK: - Credentials

    struct Credentials: Equatable {
        var accessToken: String
        var plan: String?
    }

    private static func readCredentials(now: Date = Date()) -> Result<Credentials, Failure> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            log.error("keychain read failed: OSStatus \(status)")
            switch status {
            case errSecItemNotFound: return .failure(.noCredentials)
            case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
                return .failure(.keychainDenied)
            default: return .failure(.keychainDenied)
            }
        }
        guard let credentials = credentials(from: data, now: now) else {
            log.info("credentials present but token expired")
            return .failure(.tokenExpired)
        }
        return .success(credentials)
    }

    /// Pure part, unit tested. Expired tokens return nil — Claude Code
    /// refreshes them whenever it runs; we never write the keychain.
    static func credentials(from data: Data, now: Date) -> Credentials? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = (object["claudeAiOauth"] as? [String: Any]) ?? object
        if let expiresAt = oauth["expiresAt"] as? Double, expiresAt / 1000 < now.timeIntervalSince1970 {
            return nil
        }
        guard let token = oauth["accessToken"] as? String else { return nil }
        return Credentials(
            accessToken: token,
            plan: UsageLimits.planName(
                tier: oauth["rateLimitTier"] as? String,
                subscription: oauth["subscriptionType"] as? String
            )
        )
    }
}
