import Foundation

/// One coding-agent session as shown on the dashboard. Deliberately
/// agent-agnostic — a future Codex/other source produces the same shape.
public struct AgentSession: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Mid-turn: the agent is thinking or running tools.
        case working
        /// The agent finished its turn and is waiting for the human.
        case awaitingInput
        /// No recent activity (interrupted or finished).
        case idle
    }

    public var id: String
    public var projectName: String
    public var branch: String?
    public var title: String?
    public var model: String?
    public var state: State
    public var lastActivity: Date

    public init(
        id: String,
        projectName: String,
        branch: String? = nil,
        title: String? = nil,
        model: String? = nil,
        state: State,
        lastActivity: Date
    ) {
        self.id = id
        self.projectName = projectName
        self.branch = branch
        self.title = title
        self.model = model
        self.state = state
        self.lastActivity = lastActivity
    }
}

/// Token consumption aggregate. `input` includes cache reads (that is what
/// the API actually processed).
public struct TokenTotals: Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var sessions: Int

    public init(input: Int = 0, output: Int = 0, sessions: Int = 0) {
        self.input = input
        self.output = output
        self.sessions = sessions
    }

    public static func + (lhs: TokenTotals, rhs: TokenTotals) -> TokenTotals {
        TokenTotals(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            sessions: lhs.sessions + rhs.sessions
        )
    }

    /// 512 → "512", 51_200 → "51k", 38_400_000 → "38M".
    public static func text(_ tokens: Int) -> String {
        switch tokens {
        case ..<1_000: "\(tokens)"
        case ..<1_000_000: String(format: "%.0fk", Double(tokens) / 1_000)
        case ..<1_000_000_000: String(format: "%.1fM", Double(tokens) / 1_000_000)
        default: String(format: "%.2fB", Double(tokens) / 1_000_000_000)
        }
    }
}
