import Foundation

/// Plan rate-limit windows as reported by Anthropic's OAuth usage endpoint —
/// the same numbers Claude Code's /usage shows (5-hour session window,
/// weekly, weekly per-model-group).
public struct UsageLimits: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        public var percent: Double // 0…100
        public var resetsAt: Date?
        public var severity: String?
        /// Scoped windows carry what they apply to (e.g. a model group).
        public var label: String?

        public init(percent: Double, resetsAt: Date? = nil, severity: String? = nil, label: String? = nil) {
            self.percent = percent
            self.resetsAt = resetsAt
            self.severity = severity
            self.label = label
        }
    }

    public var session: Window?
    public var weeklyAll: Window?
    public var weeklyScoped: Window?

    public init(session: Window? = nil, weeklyAll: Window? = nil, weeklyScoped: Window? = nil) {
        self.session = session
        self.weeklyAll = weeklyAll
        self.weeklyScoped = weeklyScoped
    }

    // MARK: - Parsing

    public static func parse(_ data: Data) -> UsageLimits? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var limits = UsageLimits()

        if let entries = object["limits"] as? [[String: Any]] {
            for entry in entries {
                let window = Window(
                    percent: (entry["percent"] as? Double) ?? Double(entry["percent"] as? Int ?? 0),
                    resetsAt: (entry["resets_at"] as? String).flatMap(parseAPITimestamp),
                    severity: entry["severity"] as? String,
                    label: scopeLabel(entry["scope"])
                )
                switch entry["kind"] as? String {
                case "session": limits.session = window
                case "weekly_all": limits.weeklyAll = window
                case "weekly_scoped": limits.weeklyScoped = window
                default: break
                }
            }
        }

        // Fallback for older response shapes.
        if limits.session == nil, let window = simpleWindow(object["five_hour"]) {
            limits.session = window
        }
        if limits.weeklyAll == nil, let window = simpleWindow(object["seven_day"]) {
            limits.weeklyAll = window
        }
        return limits.session == nil && limits.weeklyAll == nil ? nil : limits
    }

    private static func simpleWindow(_ value: Any?) -> Window? {
        guard let dict = value as? [String: Any],
              let utilization = dict["utilization"] as? Double else { return nil }
        return Window(
            percent: utilization,
            resetsAt: (dict["resets_at"] as? String).flatMap(parseAPITimestamp)
        )
    }

    private static func scopeLabel(_ value: Any?) -> String? {
        guard let dict = value as? [String: Any] else { return nil }
        return (dict["model"] as? String) ?? dict.values.compactMap { $0 as? String }.first
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
    public init() {}

    public func fetch() async -> UsageLimits? {
        guard let token = Self.accessToken() else { return nil }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return UsageLimits.parse(data)
    }

    // MARK: - Credentials

    private static func accessToken(now: Date = Date()) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return accessToken(from: data, now: now)
    }

    /// Pure part, unit tested. Expired tokens return nil — Claude Code
    /// refreshes them whenever it runs; we never write the keychain.
    static func accessToken(from data: Data, now: Date) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = (object["claudeAiOauth"] as? [String: Any]) ?? object
        if let expiresAt = oauth["expiresAt"] as? Double, expiresAt / 1000 < now.timeIntervalSince1970 {
            return nil
        }
        return oauth["accessToken"] as? String
    }
}
