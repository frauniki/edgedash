import EdgeCore
import EdgeMetrics
import SwiftUI
import WidgetEngine

public struct MemoryWidget: WidgetDefinition {
    public struct Config: Codable, Sendable, DefaultInitializable {
        public var showBreakdown = true
        public var showSwap = true
        public var showPressure = true
        public var showProcesses = true
        public var processCount = 3
        public init() {}
    }

    public static let typeID = WidgetTypeID("edgedash.memory")
    public static let displayName = "Memory"
    public static let category = WidgetCategory.monitoring
    public static let supportedSizes = [
        GridSize(cols: 1, rows: 1), GridSize(cols: 2, rows: 1), GridSize(cols: 2, rows: 2),
    ]

    public static func requiredMetrics(for config: Config) -> Set<MetricID> {
        var ids: Set<MetricID> = [.memoryUsage]
        if config.showBreakdown { ids.insert(.memoryBreakdown) }
        if config.showPressure { ids.insert(.memoryPressure) }
        if config.showProcesses { ids.insert(.topProcessesMemory) }
        return ids
    }

    @MainActor public static func makeView(config: Config, context: WidgetContext) -> AnyView {
        AnyView(MemoryView(
            config: config,
            usage: context.hub.store(for: .memoryUsage),
            breakdown: context.hub.store(for: .memoryBreakdown),
            pressure: context.hub.store(for: .memoryPressure),
            processes: context.hub.store(for: .topProcessesMemory),
            size: context.size
        ))
    }

    @MainActor public static func makeConfigView(config: Binding<Config>) -> AnyView {
        AnyView(MemoryConfigView(config: config))
    }
}

private struct MemoryView: View {
    @Environment(\.theme) private var theme
    let config: MemoryWidget.Config
    let usage: MetricStore
    let breakdown: MetricStore
    let pressure: MetricStore
    let processes: MetricStore
    let size: GridSize

    private var fraction: Double {
        if case .scalar(let v)? = usage.latest { v } else { 0 }
    }

    private var details: [String: Double] {
        if case .composite(let v)? = breakdown.latest { v } else { [:] }
    }

    private var accent: Color {
        theme.gaugeColor(fraction, warn: 0.8, critical: 0.92).color
    }

    private var percentText: String {
        String(format: "%.0f%%", fraction * 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if size.cols >= 2 || size.rows >= 2 {
                WidgetTitle(text: "MEMORY", value: nil)
                HStack(spacing: 18) {
                    LabeledRing(fraction: fraction, color: accent, label: percentText)
                    if config.showBreakdown {
                        VStack(alignment: .leading, spacing: 4) {
                            breakdownRows
                            Spacer(minLength: 4)
                            SparklineView(history: usage.history, maxValue: 1, color: accent)
                                .frame(height: 36)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                WidgetTitle(text: "MEMORY", value: nil)
                LabeledRing(fraction: fraction, color: accent, label: percentText)
            }
        }
        .padding(14)
    }

    @ViewBuilder private var breakdownRows: some View {
        row("Used", details["used"])
        row("App", details["app"])
        row("Wired", details["wired"])
        row("Compressed", details["compressed"])
        if config.showSwap {
            row("Swap", details["swapUsed"])
        }
        if config.showPressure, case .scalar(let level)? = pressure.latest {
            HStack {
                Text("Pressure").foregroundStyle(theme.textSecondary.color)
                Spacer()
                Text(Self.pressureLabel(level))
                    .foregroundStyle(Self.pressureColor(level, theme: theme))
            }
            .font(.system(size: 14, design: .rounded))
        }
        if config.showProcesses, !topProcesses.isEmpty {
            Divider().padding(.vertical, 2)
            ForEach(topProcesses, id: \.name) { process in
                HStack {
                    Text(process.name)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(Self.gib(process.bytes))
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary.color)
                }
                .font(.system(size: 12, design: .rounded))
            }
        }
    }

    private var topProcesses: [(name: String, bytes: Double)] {
        guard case .composite(let values)? = processes.latest else { return [] }
        return values.sorted { $0.value > $1.value }
            .prefix(max(1, config.processCount))
            .map { (name: $0.key, bytes: $0.value) }
    }

    static func pressureLabel(_ level: Double) -> String {
        level >= 4 ? "critical" : level >= 2 ? "warning" : "normal"
    }

    static func pressureColor(_ level: Double, theme: Theme) -> Color {
        level >= 4 ? theme.critical.color : level >= 2 ? theme.warn.color : theme.accent.color
    }

    private func row(_ label: String, _ bytes: Double?) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(theme.textSecondary.color)
            Spacer()
            Text(bytes.map(Self.gib) ?? "—")
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
        }
        .font(.system(size: 14, design: .rounded))
    }

    private static func gib(_ bytes: Double) -> String {
        String(format: "%.1f GB", bytes / 1_073_741_824)
    }
}

private struct MemoryConfigView: View {
    @Binding var config: MemoryWidget.Config

    var body: some View {
        Form {
            Toggle("Breakdown", isOn: $config.showBreakdown)
            Toggle("Swap", isOn: $config.showSwap)
            Toggle("Memory pressure", isOn: $config.showPressure)
            Toggle("Top processes", isOn: $config.showProcesses)
            Stepper("Processes: \(config.processCount)", value: $config.processCount, in: 1...8)
        }
    }
}
