@testable import AgentWidgets
import Foundation
import Testing

// MARK: - Fixture helpers

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func assistantLine(
    stop: String?,
    timestamp: Date,
    output: Int = 100,
    input: Int = 10,
    cacheRead: Int = 0,
    model: String = "claude-fable-5",
    cwd: String = "/Users/dev/myproject"
) -> String {
    let stopJSON = stop.map { "\"\($0)\"" } ?? "null"
    // swiftlint:disable line_length
    return """
    {"type":"assistant","timestamp":"\(iso(timestamp))","cwd":"\(cwd)","gitBranch":"main","sessionId":"s1","message":{"model":"\(model)","stop_reason":\(stopJSON),"usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead)}}}
    """
    // swiftlint:enable line_length
}

private func userPromptLine(timestamp: Date, cwd: String = "/Users/dev/myproject") -> String {
    """
    {"type":"user","timestamp":"\(iso(timestamp))","cwd":"\(cwd)","gitBranch":"main","message":{"role":"user","content":"do the thing"}}
    """
}

private func toolResultLine(timestamp: Date) -> String {
    """
    {"type":"user","timestamp":"\(iso(timestamp))","cwd":"/Users/dev/myproject","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
    """
}

private func titleLine(_ title: String) -> String {
    #"{"type":"ai-title","sessionId":"s1","aiTitle":"\#(title)"}"#
}

/// Temp `projects/<slug>/<session>.jsonl` tree for scanner tests.
private struct FixtureTree {
    let root: URL
    let file: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-tests-\(UUID().uuidString)")
        let projectDir = root.appendingPathComponent("-Users-dev-myproject")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        file = projectDir.appendingPathComponent("session-1.jsonl")
    }

    func write(_ lines: [String], terminated: Bool = true) throws {
        let text = lines.joined(separator: "\n") + (terminated ? "\n" : "")
        try Data(text.utf8).write(to: file)
    }

    func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func destroy() {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Pure parsing

struct ParseTests {
    private let now = Date()

    private func parsed(_ json: String) -> ClaudeSessionScanner.ParsedLine {
        // Fixture JSON is trusted.
        // swiftlint:disable:next force_try force_cast
        let obj = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return ClaudeSessionScanner.parse(obj)
    }

    private func shape(of json: String) -> ClaudeSessionScanner.MessageShape? {
        if case .message(let shape, _, _, _, _, _) = parsed(json) { shape } else { nil }
    }

    @Test func shapesAreClassified() {
        #expect(shape(of: assistantLine(stop: "end_turn", timestamp: now)) == .assistantEndTurn)
        #expect(shape(of: assistantLine(stop: "tool_use", timestamp: now)) == .assistantMidTurn)
        #expect(shape(of: toolResultLine(timestamp: now)) == .toolResult)
        #expect(shape(of: userPromptLine(timestamp: now)) == .userPrompt)
    }

    @Test func usageSplitsTokenClasses() {
        guard case .message(_, _, _, _, let model, let counts) =
            parsed(assistantLine(stop: "end_turn", timestamp: now, output: 50, input: 7, cacheRead: 1000))
        else {
            Issue.record("not a message"); return
        }
        #expect(counts == TokenCounts(input: 7, cacheRead: 1000, cacheWrite: 0, output: 50))
        #expect(counts.allInput == 1007)
        #expect(model == "claude-fable-5")
    }

    @Test func titleParses() {
        #expect(parsed(titleLine("実装完了の確認")) == .title("実装完了の確認"))
    }

    @Test func stateClassification() {
        // swiftlint:disable:next type_name
        typealias S = ClaudeSessionScanner
        // end_turn is "your turn" no matter how fresh.
        #expect(S.classify(lastShape: .assistantEndTurn, lastActivity: now, now: now) == .awaitingInput)
        // Mid-turn survives long silent tool runs (< 10 min).
        #expect(S.classify(lastShape: .assistantMidTurn, lastActivity: now.addingTimeInterval(-300), now: now) == .working)
        #expect(S.classify(lastShape: .toolResult, lastActivity: now.addingTimeInterval(-300), now: now) == .working)
        // …but not forever.
        #expect(S.classify(lastShape: .toolResult, lastActivity: now.addingTimeInterval(-700), now: now) == .idle)
        // Unknown stop_reason leans on recency.
        #expect(S.classify(lastShape: .assistantUnknown, lastActivity: now, now: now) == .working)
        #expect(S.classify(lastShape: .assistantUnknown, lastActivity: now.addingTimeInterval(-60), now: now) == .idle)
    }

    @Test func helpers() {
        #expect(ClaudeSessionScanner.projectName(cwd: "/a/b/edgedash", containerDir: "/x") == "edgedash")
        #expect(ClaudeSessionScanner.shortModel("claude-fable-5") == "fable-5")
        #expect(TokenTotals.text(512) == "512")
        #expect(TokenTotals.text(51200) == "51k")
        #expect(TokenTotals.text(38_400_000) == "38.4M")
    }
}

// MARK: - Scanner integration

struct ScannerTests {
    @Test func fullScanBuildsSession() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let now = Date()
        try tree.write([
            userPromptLine(timestamp: now.addingTimeInterval(-120)),
            titleLine("Fix the bug"),
            assistantLine(stop: "tool_use", timestamp: now.addingTimeInterval(-60), output: 500, input: 20, cacheRead: 980),
            toolResultLine(timestamp: now.addingTimeInterval(-50)),
        ])

        let scanner = ClaudeSessionScanner(root: tree.root)
        let snap = await scanner.scan(now: now)
        #expect(snap.sessions.count == 1)
        let session = try #require(snap.sessions.first)
        #expect(session.projectName == "myproject")
        #expect(session.branch == "main")
        #expect(session.title == "Fix the bug")
        #expect(session.model == "fable-5")
        #expect(session.state == .working)
        #expect(snap.todayTotals == TokenTotals(input: 1000, output: 500, sessions: 1))
    }

    @Test func incrementalAppendAndMidLineChunk() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let now = Date()
        try tree.write([assistantLine(stop: "tool_use", timestamp: now, output: 100)])

        let scanner = ClaudeSessionScanner(root: tree.root)
        var snap = await scanner.scan(now: now)
        #expect(snap.todayTotals.output == 100)

        // Append a line WITHOUT its trailing newline — a scan mid-write.
        let next = assistantLine(stop: "end_turn", timestamp: now, output: 25)
        let cut = next.index(next.startIndex, offsetBy: next.count / 2)
        try tree.append(String(next[..<cut]))
        snap = await scanner.scan(now: now)
        #expect(snap.todayTotals.output == 100) // incomplete line not counted
        #expect(snap.sessions.first?.state == .working) // still the old shape

        // The rest arrives; the split line parses exactly once.
        try tree.append(String(next[cut...]) + "\n")
        snap = await scanner.scan(now: now)
        #expect(snap.todayTotals.output == 125)
        #expect(snap.sessions.first?.state == .awaitingInput)
    }

    @Test func truncationReplacesContribution() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let now = Date()
        try tree.write([
            assistantLine(stop: "tool_use", timestamp: now, output: 1000),
            assistantLine(stop: "tool_use", timestamp: now, output: 1000),
        ])
        let scanner = ClaudeSessionScanner(root: tree.root)
        var snap = await scanner.scan(now: now)
        #expect(snap.todayTotals.output == 2000)

        // File rewritten smaller: old contribution must vanish, not stack.
        try tree.write([assistantLine(stop: "end_turn", timestamp: now, output: 300)])
        snap = await scanner.scan(now: now)
        #expect(snap.todayTotals.output == 300)
    }

    @Test func deletedFileDropsOut() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let now = Date()
        try tree.write([assistantLine(stop: "end_turn", timestamp: now, output: 42)])
        let scanner = ClaudeSessionScanner(root: tree.root)
        var snap = await scanner.scan(now: now)
        #expect(snap.todayTotals.output == 42)

        try FileManager.default.removeItem(at: tree.file)
        snap = await scanner.scan(now: now)
        #expect(snap.sessions.isEmpty)
        #expect(snap.todayTotals == TokenTotals())
    }

    @Test func yesterdayTokensExcludedFromToday() async throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let now = Date()
        try tree.write([
            assistantLine(stop: "tool_use", timestamp: now.addingTimeInterval(-26 * 3600), output: 999),
            assistantLine(stop: "end_turn", timestamp: now, output: 5),
        ])
        let scanner = ClaudeSessionScanner(root: tree.root)
        let snap = await scanner.scan(now: now)
        #expect(snap.todayTotals.output == 5)
    }
}
