import EdgeCore
import EdgeTouch
import SwiftUI
import WidgetEngine

public struct ClaudeCodeWidget: WidgetDefinition {
    public struct Config: Codable, Sendable, DefaultInitializable {
        public var windowHours = 8.0
        public var maxRows = 5
        public var showTokens = true
        public var showTitles = true
        public var showBranch = true
        public var showLimits = true
        public var showCost = true
        public init() {}

        /// Lenient decoding: adding fields must not reset saved configs.
        private enum CodingKeys: String, CodingKey {
            case windowHours, maxRows, showTokens, showTitles, showBranch, showLimits, showCost
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            windowHours = try container.decodeIfPresent(Double.self, forKey: .windowHours) ?? 8
            maxRows = try container.decodeIfPresent(Int.self, forKey: .maxRows) ?? 5
            showTokens = try container.decodeIfPresent(Bool.self, forKey: .showTokens) ?? true
            showTitles = try container.decodeIfPresent(Bool.self, forKey: .showTitles) ?? true
            showBranch = try container.decodeIfPresent(Bool.self, forKey: .showBranch) ?? true
            showLimits = try container.decodeIfPresent(Bool.self, forKey: .showLimits) ?? true
            showCost = try container.decodeIfPresent(Bool.self, forKey: .showCost) ?? true
        }
    }

    public static let typeID = WidgetTypeID("edgedash.claudecode")
    public static let displayName = "Claude Code"
    public static let category = WidgetCategory.agent
    public static let supportedSizes = [
        GridSize(cols: 1, rows: 1), GridSize(cols: 2, rows: 1),
        GridSize(cols: 2, rows: 2), GridSize(cols: 4, rows: 2),
    ]

    public static func requiredMetrics(for config: Config) -> Set<MetricID> {
        []
    }

    @MainActor public static func makeView(config: Config, context: WidgetContext) -> AnyView {
        guard let monitor = context.services.resolve(ClaudeCodeMonitor.self) else {
            return AnyView(
                Text("Agent service unavailable")
                    .font(.system(size: 12, design: .rounded))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }
        return AnyView(ClaudeCodeView(config: config, monitor: monitor, size: context.size))
    }

    @MainActor public static func makeConfigView(config: Binding<Config>, context: WidgetContext) -> AnyView {
        AnyView(ClaudeCodeConfigView(config: config))
    }

    /// "48m", "2h05m", "6d10h".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total >= 86400 { return "\(total / 86400)d\((total % 86400) / 3600)h" }
        if total >= 3600 { return "\(total / 3600)h\(String(format: "%02d", (total % 3600) / 60))m" }
        return "\(max(1, total / 60))m"
    }
}

private struct ClaudeCodeView: View {
    @Environment(\.theme) private var theme
    let config: ClaudeCodeWidget.Config
    let monitor: ClaudeCodeMonitor
    let size: GridSize

    private var visibleSessions: [AgentSession] {
        let cutoff = Date().addingTimeInterval(-config.windowHours * 3600)
        return monitor.sessions.filter { $0.lastActivity > cutoff }
    }

    private var workingCount: Int {
        visibleSessions.count { $0.state == .working }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            WidgetTitle(
                text: monitor.usage?.plan.map { "CLAUDE CODE · \($0.uppercased())" } ?? "CLAUDE CODE",
                value: "\(workingCount)"
            )
            if config.showLimits {
                if let usage = monitor.usage {
                    limitRows(usage)
                } else if let failure = monitor.usageFailure {
                    Text(Self.failureText(failure))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.warn.color)
                        .lineLimit(1)
                }
            }
            if visibleSessions.isEmpty {
                Text("No recent sessions")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if size.cols == 1 {
                miniLayout
            } else {
                listLayout
            }
            if config.showCost, size.rows >= 2 {
                costStats
            } else if config.showTokens, size.cols >= 2 || size.rows >= 2 {
                totalsLine
            }
        }
        .padding(14)
    }

    /// 1×1: state dots + today's output tokens.
    private var miniLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(visibleSessions.prefix(8)) { session in
                    StateDot(state: session.state, theme: theme)
                }
                Spacer(minLength: 0)
            }
            ForEach(visibleSessions.prefix(3)) { session in
                HStack(spacing: 6) {
                    StateDot(state: session.state, theme: theme)
                    Text(session.projectName)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(Self.age(session.lastActivity))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var listLayout: some View {
        TouchScrollView {
            VStack(alignment: .leading, spacing: size.rows >= 2 ? 6 : 4) {
                ForEach(visibleSessions.prefix(max(1, config.maxRows))) { session in
                    sessionRow(session)
                }
            }
        }
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StateDot(state: session.state, theme: theme)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1)
                    if config.showBranch, let branch = session.branch {
                        Text(branch)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1)
                    }
                }
                if config.showTitles, size.rows >= 2, let title = session.title {
                    Text(title)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(stateText(session.state))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(stateColor(session.state))
                HStack(spacing: 5) {
                    if size.rows >= 2, let model = session.model {
                        Text(model)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(theme.textSecondary.color)
                    }
                    Text(Self.age(session.lastActivity))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
        }
    }

    /// CodexBar-style plan limit bars: every window the API reports, with
    /// remaining %, reset countdown, and shortfall forecast when burning fast.
    private func limitRows(_ usage: UsageLimits) -> some View {
        VStack(spacing: 3) {
            ForEach(usage.windows) { window in
                limitRow(window, forecast: monitor.forecasts[window.id])
            }
        }
    }

    private func limitRow(_ window: UsageLimits.Window, forecast: ClaudeCodeMonitor.Forecast?) -> some View {
        let fraction = min(max(window.percent / 100, 0), 1)
        let untilReset = window.resetsAt.map(\.timeIntervalSinceNow)
        return HStack(spacing: 6) {
            Text(window.label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: size.cols == 1 ? 46 : (size.cols >= 4 ? 70 : 52), alignment: .leading)
                .lineLimit(1)
            MeterBar(fraction: fraction, color: theme.gaugeColor(fraction, warn: 0.7, critical: 0.9).color)
            Text(String(format: "%.0f%% left", window.remaining))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.textPrimary.color)
                .frame(width: 52, alignment: .trailing)
            if size.cols >= 2, let untilReset, untilReset > 0 {
                Text("→\(ClaudeCodeWidget.duration(untilReset))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(width: 48, alignment: .trailing)
            }
            // "4% short, dry in 1h48m" — only when the pace beats the reset.
            if size.cols >= 2, let forecast, let short = forecast.shortfallPercent {
                Text("⚠\(Int(short))%\(forecast.depletionIn.map { " " + ClaudeCodeWidget.duration($0) } ?? "")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.warn.color)
                    .lineLimit(1)
            }
        }
    }

    /// today/30d dollars + latest/30d tokens + top model + daily-cost bars,
    /// from local transcripts at API list rates (estimate, like CodexBar).
    @ViewBuilder private var costStats: some View {
        let stats = monitor.stats
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Text("today \(ModelPricing.dollars(stats.costToday)) · latest \(TokenTotals.text(stats.latestSessionTokens))")
                Spacer(minLength: 8)
                Text("30d \(ModelPricing.dollars(stats.cost30d)) · \(TokenTotals.text(stats.tokens30d))\(stats.topModel.map { " · \(shortScope($0))" } ?? "")")
            }
            .font(.system(size: 11, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(theme.textSecondary.color)
            .lineLimit(1)
            DailyCostBars(values: stats.dailyCosts, color: theme.accentAlt.color)
                .frame(height: 24)
        }
    }

    private func shortScope(_ label: String) -> String {
        label.hasPrefix("claude-") ? String(label.dropFirst("claude-".count)) : label
    }

    static func failureText(_ failure: ClaudeUsageFetcher.Failure) -> String {
        switch failure {
        case .keychainDenied: "limits: keychain access denied"
        case .noCredentials: "limits: no Claude Code login"
        case .tokenExpired: "limits: token expired — run claude"
        case .requestFailed: "limits: unavailable"
        }
    }

    private var totalsLine: some View {
        let totals = monitor.todayTotals
        return Text("today  ↓\(TokenTotals.text(totals.input))  ↑\(TokenTotals.text(totals.output))  ·  \(totals.sessions) sessions")
            .font(.system(size: 11, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(theme.textSecondary.color)
            .lineLimit(1)
    }

    private func stateText(_ state: AgentSession.State) -> String {
        switch state {
        case .working: "working"
        case .awaitingInput: "your turn"
        case .idle: "idle"
        }
    }

    private func stateColor(_ state: AgentSession.State) -> Color {
        switch state {
        case .working: theme.accent.color
        case .awaitingInput: theme.warn.color
        case .idle: theme.textSecondary.color
        }
    }

    static func age(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        default: return "\(Int(seconds / 3600))h"
        }
    }
}

/// Daily cost bar chart (30 days, newest right) with a peak-dollar label —
/// discrete daily buckets read better as bars than as a line.
private struct DailyCostBars: View {
    @Environment(\.theme) private var theme
    let values: [Double]
    let color: Color

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Canvas { context, size in
                guard let peak = values.max(), peak > 0 else { return }
                let count = CGFloat(max(values.count, 1))
                let gap: CGFloat = 2
                let barWidth = max((size.width - gap * (count - 1)) / count, 1)
                for (index, value) in values.enumerated() {
                    let height = max(size.height * CGFloat(value / peak), value > 0 ? 1.5 : 0)
                    guard height > 0 else { continue }
                    let rect = CGRect(
                        x: CGFloat(index) * (barWidth + gap),
                        y: size.height - height,
                        width: barWidth,
                        height: height
                    )
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(0.85)))
                }
            }
            if let peak = values.max(), peak > 0 {
                Text(ModelPricing.dollars(peak))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.textSecondary.color)
            }
        }
    }
}

/// Session state dot; pulses while the agent is working.
private struct StateDot: View {
    let state: AgentSession.State
    let theme: Theme
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(state == .working && dim ? 0.3 : 1)
            .animation(
                state == .working ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                value: dim
            )
            .onAppear { dim = true }
    }

    private var color: Color {
        switch state {
        case .working: theme.accent.color
        case .awaitingInput: theme.warn.color
        case .idle: theme.textSecondary.color.opacity(0.5)
        }
    }
}

private struct ClaudeCodeConfigView: View {
    @Binding var config: ClaudeCodeWidget.Config

    var body: some View {
        ConfigForm {
            LabeledContent(loc("Window")) {
                HStack(spacing: 8) {
                    Slider(value: $config.windowHours, in: 1...24, step: 1)
                    Text(String(format: "%.0f h", config.windowHours))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            Stepper(loc("Rows: \(config.maxRows)"), value: $config.maxRows, in: 1...12)
            Toggle(loc("Plan limits (5h/weekly)"), isOn: $config.showLimits)
            Toggle(loc("Cost estimate ($, 30 days)"), isOn: $config.showCost)
            Toggle(loc("Today's tokens"), isOn: $config.showTokens)
            Toggle(loc("Session titles"), isOn: $config.showTitles)
            Toggle(loc("Git branch"), isOn: $config.showBranch)
        }
    }
}
