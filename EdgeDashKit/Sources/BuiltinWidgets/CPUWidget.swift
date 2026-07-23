import EdgeCore
import EdgeMetrics
import SMCBridge
import SwiftUI
import WidgetEngine

public struct CPUWidget: WidgetDefinition {
    public struct Config: Codable, Sendable, DefaultInitializable {
        public var showPerCore = true          // per-core ring rows (E/P clusters)
        public var showHistory = true          // stacked user/system histogram
        public var showLoadAverage = true
        public var showUptime = true
        public var showProcesses = true
        public var showTemperature = true
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
        if config.showPerCore { ids.formUnion([.cpuPerCore, .cpuTopology]) }
        if config.showLoadAverage { ids.insert(.cpuLoadAverage) }
        if config.showProcesses { ids.insert(.topProcessesCPU) }
        if config.showTemperature { ids.insert(.temperatures) }
        return ids
    }

    @MainActor public static func makeView(config: Config, context: WidgetContext) -> AnyView {
        AnyView(CPUView(
            config: config,
            usage: context.hub.store(for: .cpuUsage),
            perCore: context.hub.store(for: .cpuPerCore),
            topology: context.hub.store(for: .cpuTopology),
            load: context.hub.store(for: .cpuLoadAverage),
            breakdown: context.hub.store(for: .cpuBreakdown),
            uptime: context.hub.store(for: .systemUptime),
            processes: context.hub.store(for: .topProcessesCPU),
            temperatures: context.hub.store(for: .temperatures),
            size: context.size
        ))
    }

    @MainActor public static func makeConfigView(config: Binding<Config>, context: WidgetContext) -> AnyView {
        AnyView(CPUConfigView(config: config))
    }
}

private struct CPUView: View {
    @Environment(\.theme) private var theme
    let config: CPUWidget.Config
    let usage: MetricStore
    let perCore: MetricStore
    let topology: MetricStore
    let load: MetricStore
    let breakdown: MetricStore
    let uptime: MetricStore
    let processes: MetricStore
    let temperatures: MetricStore
    let size: GridSize

    // MARK: - Data

    private var fraction: Double {
        if case .scalar(let v)? = usage.latest { v } else { 0 }
    }

    private var cores: [Double] {
        if case .perCore(let v)? = perCore.latest { v } else { [] }
    }

    /// (efficiency, performance) core slices; E cores come first in the array.
    private var clusters: (e: [Double], p: [Double]) {
        guard case .composite(let topo)? = topology.latest,
              let eCount = topo["e"].map(Int.init), eCount > 0, cores.count > eCount else {
            return (e: [], p: cores)
        }
        return (e: Array(cores.prefix(eCount)), p: Array(cores.dropFirst(eCount)))
    }

    private var split: (user: Double, system: Double)? {
        guard case .composite(let values)? = breakdown.latest,
              let user = values["user"], let system = values["system"] else { return nil }
        return (user, system)
    }

    private var splitHistory: [(bottom: Double, top: Double)] {
        breakdown.history.compactMap { point in
            guard case .composite(let values) = point.value,
                  let user = values["user"], let system = values["system"] else { return nil }
            return (bottom: user, top: system)
        }
    }

    private var cpuTemperature: Double? {
        guard config.showTemperature, case .composite(let sensors)? = temperatures.latest else { return nil }
        let dieTemps = sensors.filter { $0.key.localizedCaseInsensitiveContains("tdie") }
        if !dieTemps.isEmpty { return dieTemps.values.max() }
        return sensors.filter { $0.key.localizedCaseInsensitiveContains("cpu") }.values.max()
    }

    private var topProcesses: [(name: String, fraction: Double)] {
        guard config.showProcesses, case .composite(let values)? = processes.latest else { return [] }
        return values.sorted { $0.value > $1.value }
            .prefix(max(1, config.processCount))
            .map { (name: $0.key, fraction: $0.value) }
    }

    private var headerValue: String {
        var text = String(format: "%.0f%%", fraction * 100)
        if let temp = cpuTemperature {
            text += String(format: "  %.0f°", temp)
        }
        return text
    }

    private var accent: Color {
        theme.gaugeColor(fraction, warn: config.warnThreshold, critical: config.criticalThreshold).color
    }

    // MARK: - Layout

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            WidgetTitle(text: "CPU", value: headerValue)
            if size.rows >= 2 {
                fullLayout
            } else {
                compactLayout
            }
        }
        .padding(14)
    }

    /// 2×2 / 4×2: histogram + legend + core rings + processes + load line.
    @ViewBuilder private var fullLayout: some View {
        if config.showHistory {
            StackedAreaHistory(
                pairs: splitHistory,
                capacity: breakdown.history.capacity,
                bottomColor: theme.accent.color,
                topColor: theme.accentAlt.color
            )
            .frame(maxHeight: .infinity)
            splitLegend
        }
        if config.showPerCore, !cores.isEmpty {
            coreRings
        }
        if !topProcesses.isEmpty {
            Divider().overlay(theme.track.color).padding(.vertical, 1)
            processRows
        }
        if let bottomLine {
            Text(bottomLine)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.textSecondary.color)
        }
    }

    /// 1×1 / 2×1: histogram + single combined core-ring row + legend.
    @ViewBuilder private var compactLayout: some View {
        if config.showHistory {
            StackedAreaHistory(
                pairs: splitHistory,
                capacity: breakdown.history.capacity,
                bottomColor: theme.accent.color,
                topColor: theme.accentAlt.color
            )
            .frame(maxHeight: .infinity)
        }
        if config.showPerCore, !cores.isEmpty {
            compactCoreRow
        }
        splitLegend
    }

    /// One row, E then P, cluster encoded by color. Ring diameter shrinks to
    /// whatever the cell width fits (1×1 is half a 2×1).
    private var compactCoreRow: some View {
        let clusters = clusters
        let spacing: CGFloat = 5
        let maxDiameter: CGFloat = 18
        return GeometryReader { proxy in
            let count = CGFloat(max(cores.count, 1))
            let diameter = min(maxDiameter, (proxy.size.width - spacing * (count - 1)) / count)
            HStack(spacing: spacing) {
                ForEach(Array(clusters.e.enumerated()), id: \.offset) { _, value in
                    MiniRing(fraction: value, color: theme.accentAlt.color)
                        .frame(width: diameter, height: diameter)
                }
                ForEach(Array(clusters.p.enumerated()), id: \.offset) { _, value in
                    MiniRing(fraction: value, color: theme.accent.color)
                        .frame(width: diameter, height: diameter)
                }
                Spacer(minLength: 0)
            }
            .frame(height: proxy.size.height)
        }
        .frame(height: maxDiameter)
    }

    private var splitLegend: some View {
        HStack(spacing: 16) {
            if let split {
                LegendRow(color: theme.accent.color, label: "user", value: String(format: "%.0f%%", split.user * 100))
                LegendRow(color: theme.accentAlt.color, label: "system", value: String(format: "%.0f%%", split.system * 100))
            }
        }
    }

    @ViewBuilder private var coreRings: some View {
        let clusters = clusters
        VStack(alignment: .leading, spacing: 5) {
            if !clusters.e.isEmpty {
                ringRow(clusters.e, color: theme.accentAlt.color)
            }
            ringRow(clusters.p, color: theme.accent.color)
            HStack(spacing: 16) {
                if !clusters.e.isEmpty {
                    LegendRow(
                        color: theme.accentAlt.color,
                        label: "efficiency",
                        value: String(format: "%.0f%%", average(clusters.e) * 100)
                    )
                }
                LegendRow(
                    color: theme.accent.color,
                    label: "performance",
                    value: String(format: "%.0f%%", average(clusters.p) * 100)
                )
            }
        }
    }

    private func ringRow(_ values: [Double], color: Color) -> some View {
        HStack(spacing: 7) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                MiniRing(fraction: value, color: color)
                    .frame(width: 22, height: 22)
            }
            Spacer(minLength: 0)
        }
    }

    private var processRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(topProcesses, id: \.name) { process in
                ProcessRow(name: process.name, value: String(format: "%.1f%%", process.fraction * 100))
            }
        }
    }

    private var bottomLine: String? {
        var parts: [String] = []
        if config.showLoadAverage, case .composite(let values)? = load.latest,
           let l1 = values["1"], let l5 = values["5"], let l15 = values["15"] {
            parts.append(String(format: "load %.2f %.2f %.2f", l1, l5, l15))
        }
        if config.showUptime, case .scalar(let seconds)? = uptime.latest, seconds > 0 {
            parts.append("up \(Self.uptimeText(seconds))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "   ")
    }

    private func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
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
            Toggle("User/system histogram", isOn: $config.showHistory)
            Toggle("Per-core rings", isOn: $config.showPerCore)
            Toggle("Load average", isOn: $config.showLoadAverage)
            Toggle("Uptime", isOn: $config.showUptime)
            Toggle("Temperature", isOn: $config.showTemperature)
            Toggle("Top processes", isOn: $config.showProcesses)
            Stepper("Processes: \(config.processCount)", value: $config.processCount, in: 1...8)
            Section("Color thresholds") {
                LabeledContent(String(format: "Warn at %.0f%%", config.warnThreshold * 100)) {
                    Slider(value: $config.warnThreshold, in: 0.3...0.95)
                }
                LabeledContent(String(format: "Critical at %.0f%%", config.criticalThreshold * 100)) {
                    Slider(value: $config.criticalThreshold, in: 0.5...1.0)
                }
            }
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
