import Foundation

/// Reads Claude Code session transcripts (`~/.claude/projects/<slug>/<id>.jsonl`)
/// incrementally: every scan stats all files (cheap) and parses only bytes
/// appended since the previous scan. Token totals are kept per file per local
/// day so midnight rollover and file truncation never double-count.
public actor ClaudeSessionScanner {
    public struct Snapshot: Sendable, Equatable {
        public var sessions: [AgentSession]
        public var todayTotals: TokenTotals
        public var stats: UsageStats

        public init(
            sessions: [AgentSession] = [],
            todayTotals: TokenTotals = TokenTotals(),
            stats: UsageStats = UsageStats()
        ) {
            self.sessions = sessions
            self.todayTotals = todayTotals
            self.stats = stats
        }
    }

    struct FileDigest {
        var offset: UInt64 = 0
        /// Bytes read past the last newline — a scan can catch a line mid-write.
        var partial = Data()
        var mtime = Date.distantPast
        var cwd: String?
        var branch: String?
        var model: String?
        var title: String?
        var lastShape: MessageShape?
        /// day → model → token classes; feeds both totals and cost estimates.
        var tokensByDay: [String: [String: TokenCounts]] = [:]
    }

    enum MessageShape: Equatable {
        case userPrompt
        case toolResult
        case assistantEndTurn
        case assistantMidTurn // tool_use etc. — the agent's turn continues
        case assistantUnknown
    }

    enum ParsedLine: Equatable {
        case message(shape: MessageShape, timestamp: Date?, cwd: String?, branch: String?, model: String?, counts: TokenCounts)
        case title(String)
        case irrelevant
    }

    /// How long a mid-turn session may stay silent (long tool runs) before we
    /// call it interrupted.
    static let midTurnGrace: TimeInterval = 600
    /// Sessions older than this are dropped entirely (widgets filter tighter).
    static let scanWindow: TimeInterval = 24 * 3600
    /// Files this recent are parsed for cost/token accounting (30-day stats).
    static let accountingWindow: TimeInterval = 30 * 24 * 3600

    private let root: URL
    private var digests: [String: FileDigest] = [:]

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    // MARK: - Scan

    public func scan(now: Date = Date()) -> Snapshot {
        let fileManager = FileManager.default
        var seen = Set<String>()

        let projectDirs = (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        for dir in projectDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let files = (try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = values.fileSize,
                      let mtime = values.contentModificationDate else { continue }
                let path = file.path
                // Never start parsing files already outside the accounting window.
                if digests[path] == nil, now.timeIntervalSince(mtime) > Self.accountingWindow { continue }
                seen.insert(path)

                var digest = digests[path] ?? FileDigest()
                if UInt64(size) < digest.offset {
                    digest = FileDigest() // truncated/rewritten: replace contribution
                }
                if UInt64(size) > digest.offset {
                    parseIncrement(of: file, into: &digest)
                }
                digest.mtime = mtime
                digests[path] = digest
            }
        }

        // Deleted transcripts drop out of the totals too.
        digests = digests.filter { seen.contains($0.key) }

        return snapshot(now: now)
    }

    private func snapshot(now: Date) -> Snapshot {
        let today = Self.dayKey(now)
        var totals = TokenTotals()
        var sessions: [AgentSession] = []
        var byDayModel: [String: [String: TokenCounts]] = [:]

        for (path, digest) in digests {
            for (day, models) in digest.tokensByDay {
                for (model, counts) in models {
                    byDayModel[day, default: [:]][model, default: TokenCounts()].add(counts)
                }
            }
            if let day = digest.tokensByDay[today] {
                let counts = day.values.reduce(into: TokenCounts()) { $0.add($1) }
                if counts.total > 0 {
                    totals.input += counts.allInput
                    totals.output += counts.output
                    totals.sessions += 1
                }
            }
            guard now.timeIntervalSince(digest.mtime) <= Self.scanWindow else { continue }
            sessions.append(AgentSession(
                id: path,
                projectName: Self.projectName(cwd: digest.cwd, containerDir: (path as NSString).deletingLastPathComponent),
                branch: digest.branch,
                title: digest.title,
                model: digest.model.map(Self.shortModel),
                state: Self.classify(lastShape: digest.lastShape, lastActivity: digest.mtime, now: now),
                lastActivity: digest.mtime
            ))
        }
        sessions.sort { $0.lastActivity > $1.lastActivity }
        var stats = UsageStats.build(byDayModel: byDayModel, now: now, dayKey: Self.dayKey)
        if let latest = digests.values.max(by: { $0.mtime < $1.mtime }) {
            stats.latestSessionTokens = latest.tokensByDay.values
                .flatMap(\.values)
                .reduce(0) { $0 + $1.total }
        }
        return Snapshot(sessions: sessions, todayTotals: totals, stats: stats)
    }

    // MARK: - Incremental reading

    private func parseIncrement(of url: URL, into digest: inout FileDigest) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: digest.offset)) != nil else { return }

        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            digest.offset += UInt64(chunk.count)
            var buffer = digest.partial + chunk
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                if !line.isEmpty,
                   let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                {
                    Self.apply(Self.parse(object), to: &digest)
                }
                buffer = buffer[buffer.index(after: newline)...]
            }
            digest.partial = Data(buffer)
        }
    }

    // MARK: - Pure parsing (unit tested)

    static func parse(_ object: [String: Any]) -> ParsedLine {
        switch object["type"] as? String {
        case "ai-title":
            if let title = object["aiTitle"] as? String { return .title(title) }
            return .irrelevant
        case "user":
            let message = object["message"] as? [String: Any]
            let isToolResult = (message?["content"] as? [[String: Any]])?
                .contains { $0["type"] as? String == "tool_result" } ?? false
            return .message(
                shape: isToolResult ? .toolResult : .userPrompt,
                timestamp: (object["timestamp"] as? String).flatMap(parseTimestamp),
                cwd: object["cwd"] as? String,
                branch: object["gitBranch"] as? String,
                model: nil, counts: TokenCounts()
            )
        case "assistant":
            let message = object["message"] as? [String: Any]
            let shape: MessageShape = switch message?["stop_reason"] as? String {
            case "end_turn": .assistantEndTurn
            case nil: .assistantUnknown
            default: .assistantMidTurn // tool_use, stop_sequence, max_tokens…
            }
            let usage = message?["usage"] as? [String: Any]
            let counts = TokenCounts(
                input: (usage?["input_tokens"] as? Int) ?? 0,
                cacheRead: (usage?["cache_read_input_tokens"] as? Int) ?? 0,
                cacheWrite: (usage?["cache_creation_input_tokens"] as? Int) ?? 0,
                output: (usage?["output_tokens"] as? Int) ?? 0
            )
            return .message(
                shape: shape,
                timestamp: (object["timestamp"] as? String).flatMap(parseTimestamp),
                cwd: object["cwd"] as? String,
                branch: object["gitBranch"] as? String,
                model: message?["model"] as? String,
                counts: counts
            )
        default:
            return .irrelevant
        }
    }

    static func apply(_ line: ParsedLine, to digest: inout FileDigest) {
        switch line {
        case .title(let title):
            digest.title = title
        case .message(let shape, let timestamp, let cwd, let branch, let model, let counts):
            digest.lastShape = shape
            if let cwd { digest.cwd = cwd }
            if let branch, branch != "HEAD" { digest.branch = branch }
            if let model { digest.model = model }
            if counts.total > 0, let timestamp {
                let day = dayKey(timestamp)
                digest.tokensByDay[day, default: [:]][model ?? "unknown", default: TokenCounts()].add(counts)
            }
        case .irrelevant:
            break
        }
    }

    /// Message-shape-first classification: long tool runs write nothing for
    /// minutes, so recency alone cannot mean "done".
    static func classify(lastShape: MessageShape?, lastActivity: Date, now: Date) -> AgentSession.State {
        let age = now.timeIntervalSince(lastActivity)
        switch lastShape {
        case .assistantEndTurn:
            return .awaitingInput
        case .userPrompt, .toolResult, .assistantMidTurn:
            return age < midTurnGrace ? .working : .idle
        case .assistantUnknown, nil:
            return age < 15 ? .working : .idle
        }
    }

    /// Local-timezone day bucket ("today" follows the user's clock, the
    /// transcripts' timestamps are UTC).
    static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func projectName(cwd: String?, containerDir: String) -> String {
        if let cwd, !cwd.isEmpty {
            return (cwd as NSString).lastPathComponent
        }
        // Fallback: last chunk of the slug directory name (lossy but stable).
        let slug = (containerDir as NSString).lastPathComponent
        return slug.split(separator: "-").last.map(String.init) ?? slug
    }

    static func shortModel(_ model: String) -> String {
        model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }

    /// ISO8601DateFormatter is documented thread-safe; the annotation just
    /// tells Swift 6 we know.
    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let isoPlain = ISO8601DateFormatter()

    static func parseTimestamp(_ text: String) -> Date? {
        isoFractional.date(from: text) ?? isoPlain.date(from: text)
    }
}
