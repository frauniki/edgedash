import EdgeCore
import EdgeMetrics
import SwiftUI
import WidgetEngine

public struct CPUWidget: WidgetDefinition {
    public struct Config: Codable, Sendable, DefaultInitializable {
        public var showPerCore = true
        public var showHistory = true
        public var showLoadAverage = true
        public var showProcesses = true
        public var processCount = 4
        public var warnThreshold = 0.7
        public var criticalThreshold = 0.9
        public init() {}
    }

    public static let typeID = WidgetTypeID("edgedash.cpu")
    public static let displayName = "CPU"
    public static let category = WidgetCategory.monitoring
    public static let supportedSizes = [
        GridSize(cols: 1, rows: 1), GridSize(cols: 2, rows: 1),
        GridSize(cols: 2, rows: 2), GridSize(cols: 4, rows: 2),
    ]

    public static func requiredMetrics(for config: Config) -> Set<MetricID> {
        var ids: Set<MetricID> = [.cpuUsage, .cpuBreakdown, .systemUptime]
        if config.showPerCore { ids.insert(.cpuPerCore) }
        if config.showLoadAverage { ids.insert(.cpuLoadAverage) }
        if config.showProcesses { ids.insert(.topProcessesCPU) }
        return ids
    }

    @MainActor public static func makeView(config: Config, context: WidgetContext) -> AnyView {
        AnyView(CPUView(
            config: config,
            usage: context.hub.store(for: .cpuUsage),
            perCore: context.hub.store(for: .cpuPerCore),
            load: context.hub.store(for: .cpuLoadAverage),
            breakdown: context.hub.store(for: .cpuBreakdown),
            uptime: context.hub.store(for: .systemUptime),
            processes: context.hub.store(for: .topProcessesCPU),
            size: context.size
        ))
    }

    @MainActor public static func makeConfigView(config: Binding<Config>) -> AnyView {
        AnyView(CPUConfigView(config: config))
    }
}

private struct CPUView: View {
    @Environment(\.theme) private var theme
    let config: CPUWidget.Config
    let usage: MetricStore
    let perCore: MetricStore
    let load: MetricStore
    let breakdown: MetricStore
    let uptime: MetricStore
    let processes: MetricStore
    let size: GridSize

    private var fraction: Double {
        if case .scalar(let v)? = usage.latest { v } else { 0 }
    }

    private var cores: [Double] {
        if case .perCore(let v)? = perCore.latest { v } else { [] }
    }

    private var accent: Color {
        theme.gaugeColor(fraction, warn: config.warnThreshold, critical: config.criticalThreshold).color
    }

    private var infoLine1: String? {
        var parts: [String] = []
        if config.showLoadAverage, case .composite(let values)? = load.latest,
           let l1 = values["1"], let l5 = values["5"], let l15 = values["15"] {
            parts.append(String(format: "load %.2f %.2f %.2f", l1, l5, l15))
        }
        if case .scalar(let seconds)? = uptime.latest, seconds > 0 {
            parts.append("up \(Self.uptimeText(seconds))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "   ")
    }

    private var infoLine2: String? {
        guard case .composite(let values)? = breakdown.latest,
              let user = values["user"], let system = values["system"] else { return nil }
        return String(format: "user %.0f%%   sys %.0f%%", user * 100, system * 100)
    }

    private var topProcesses: [(name: String, fraction: Double)] {
        guard config.showProcesses, case .composite(let values)? = processes.latest else { return [] }
        return values.sorted { $0.value > $1.value }
            .prefix(max(1, config.processCount))
            .map { (name: $0.key, fraction: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetTitle(text: "CPU", value: percentText)
            if size.rows >= 2 || size.cols >= 2 {
                Group {
                    if let infoLine1 { infoText(infoLine1) }
                    if let infoLine2 { infoText(infoLine2) }
                }
                if config.showHistory {
                    SparklineView(history: usage.history, maxValue: 1, color: accent)
                        .frame(maxHeight: .infinity)
                }
                if size.rows >= 2, !topProcesses.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(topProcesses, id: \.name) { process in
                            HStack {
                                Text(process.name)
                                    .foregroundStyle(theme.textSecondary.color)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(String(format: "%.1f%%", process.fraction * 100))
                                    .monospacedDigit()
                                    .foregroundStyle(theme.textPrimary.color)
                            }
                            .font(.system(size: 12, design: .rounded))
                        }
                    }
                }
                if config.showPerCore, !cores.isEmpty {
                    CoreBars(cores: cores, color: accent)
                        .frame(height: size.rows >= 2 ? 26 : 20)
                }
            } else {
                LabeledRing(fraction: fraction, color: accent, label: percentText)
            }
        }
        .padding(14)
    }

    private func infoText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(theme.textSecondary.color)
    }

    private var percentText: String {
        String(format: "%.0f%%", fraction * 100)
    }

    static func uptimeText(_ seconds: Double) -> String {
        let days = Int(seconds) / 86400
        let hours = (Int(seconds) % 86400) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return days > 0 ? "\(days)d \(hours)h" : hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

private struct CPUConfigView: View {
    @Binding var config: CPUWidget.Config

    var body: some View {
        Form {
            Toggle("Per-core bars", isOn: $config.showPerCore)
            Toggle("History graph", isOn: $config.showHistory)
            Toggle("Load average", isOn: $config.showLoadAverage)
            Toggle("Top processes", isOn: $config.showProcesses)
            Stepper("Processes: \(config.processCount)", value: $config.processCount, in: 1...8)
        }
    }
}

/// Common "TITLE          value" header line for monitoring widgets.
struct WidgetTitle: View {
    @Environment(\.theme) private var theme
    let text: String
    var value: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textSecondary.color)
                .kerning(1.5)
            Spacer()
            if let value {
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary.color)
            }
        }
    }
}
